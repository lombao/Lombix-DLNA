package LDLNA::HTTPServer;
#
# Lombix DLNA - a perl DLNA media server
# Copyright (C) 2013 Cesar Lombao <lombao@lombix.com>
#
#
# pDLNA - a perl DLNA media server
# Copyright (C) 2010-2013 Stefan Heumader <stefan@heumader.at>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;

use File::Basename;
use Fcntl;
use Data::Dumper;
use Date::Format;
use GD;
use IO::Select;
use Socket;
use threads;
use threads::shared;
use XML::Simple;
require bytes;
no bytes;

use LDLNA::Config;
use LDLNA::ContentLibrary;
use LDLNA::Database;
use LDLNA::Devices;
use LDLNA::HTTPXML;
use LDLNA::Log;
use LDLNA::SpecificViews;

sub start_webserver
{
	LDLNA::Log::log('Starting HTTP Server listening on '.$CONFIG{'LOCAL_IPADDR'}.':'.$CONFIG{'HTTP_PORT'}.'.', 0, 'default');

	# got inspired by: http://www.adp-gmbh.ch/perl/webserver/
	local *S;
	socket(S, PF_INET, SOCK_STREAM, getprotobyname('tcp')) || die "Can't open HTTPServer socket: $!\n";
	setsockopt(S, SOL_SOCKET, SO_REUSEADDR, 1);
	my $server_ip = inet_aton($CONFIG{'LOCAL_IPADDR'});
	bind(S, sockaddr_in($CONFIG{'HTTP_PORT'}, $server_ip));
	listen(S, 5) || die "Can't listen to HTTPServer socket: $!\n";

	my $ss = IO::Select->new();
	$ss->add(*S);

	while(1)
	{
		my @connections_pending = $ss->can_read(60);
		foreach my $connection (@connections_pending)
		{
			my $FH;
			my $remote = accept($FH, $connection);
			my ($peer_src_port, $peer_addr) = sockaddr_in($remote);
			my $peer_ip_addr = inet_ntoa($peer_addr);

			my $thread = threads->create(\&handle_connection, $FH, $peer_ip_addr, $peer_src_port);
			$thread->detach();
		}
	}
}

sub handle_connection
{
	my $FH = shift;
	my $peer_ip_addr = shift;
	my $peer_src_port = shift;

	my $response = undef;

	LDLNA::Log::log('Incoming HTTP connection from '.$peer_ip_addr.':'.$peer_src_port.'.', 3, 'httpgeneric');

	# Check if the peer is one of our allowed clients
	my $client_allowed = 0;
	foreach my $block (@{$CONFIG{'ALLOWED_CLIENTS'}})
	{
		$client_allowed++ if $block->match($peer_ip_addr);
	}

	unless ($client_allowed)
	{
		LDLNA::Log::log('Received HTTP request from NOT allowed client IP '.$peer_ip_addr.'.', 2, 'httpgeneric');
		$response = http_header({
			'statuscode' => 403,
			'content_type' => 'text/plain',
		});

		print $FH $response;
		close($FH);
		return 0;
	}

	#
	# PARSING HTTP REQUEST
	#
	binmode($FH);

	my %CGI = ();
	my %ENV = ();

	my $post_xml = undef;
	my $request_line = <$FH>;
	my $first_line = '';
	while (defined($request_line) && $request_line ne "\r\n")
	{
		next unless $request_line;
		$request_line =~ s/\r\n//g;
		chomp($request_line);

		if (!$first_line)
		{
			$first_line = $request_line;

			my @parts = split(' ', $first_line);
			close $FH if @parts != 3;

			$ENV{'METHOD'} = $parts[0];
			$ENV{'OBJECT'} = $parts[1];
			$ENV{'HTTP_VERSION'} = $parts[2];
		}
		else
		{
			my ($name, $value) = split(':', $request_line, 2);
			$name = uc($name);
			$value =~ s/^\s//g;
			$CGI{$name} = $value;
		}
		$request_line = <$FH>;
	}

	if (!defined($ENV{'METHOD'}) || !defined($ENV{'OBJECT'}))
	{
		LDLNA::Log::log('Error parsing HTTP request from '.$peer_ip_addr.':'.$peer_src_port.'.', 2, 'httpstream');
		$response = http_header({
			'statuscode' => 501,
			'content_type' => 'text/plain',
		});

		print $FH $response;
		close($FH);
		return 0;
	}

	my $debug_string = '';
	foreach my $key (keys %CGI)
	{
		$debug_string .= "\n\t".$key.' -> '.$CGI{$key};
	}
	LDLNA::Log::log($ENV{'METHOD'}.' '.$ENV{'OBJECT'}.' from '.$peer_ip_addr.':'.$peer_src_port.':'.$debug_string, 3, 'httpgeneric');

	#
	# Reading POSTDATA, PARSING XML
	#
	if ($ENV{'METHOD'} eq "POST")
	{
		if (defined($CGI{'CONTENT-LENGTH'}) && length($CGI{'CONTENT-LENGTH'}) > 0)
		{
			LDLNA::Log::log('Reading '.$CGI{'CONTENT-LENGTH'}.' bytes from request for POSTDATA.', 2, 'httpgeneric');
			read($FH, $CGI{'POSTDATA'}, $CGI{'CONTENT-LENGTH'});
		}
		else
		{
			LDLNA::Log::log('Looking for \r\n in request for POSTDATA.', 2, 'httpgeneric');
			$CGI{'POSTDATA'} = <$FH>;
		}
		LDLNA::Log::log('POSTDATA: '.$CGI{'POSTDATA'}, 3, 'httpgeneric');

		my $xmlsimple = XML::Simple->new();
		eval { $post_xml = $xmlsimple->XMLin($CGI{'POSTDATA'}) };
		if ($@)
		{
			LDLNA::Log::log('Error converting POSTDATA with XML::Simple for '.$peer_ip_addr.':'.$peer_src_port.': '.$@, 3, 'httpdir');
		}
		else
		{
			LDLNA::Log::log('Finished converting POSTDATA with XML::Simple for '.$peer_ip_addr.':'.$peer_src_port.'.', 3, 'httpdir');
		}
	}

	# adding device and/or request to Devices tables
	LDLNA::Devices::add_device(
		
		{
			'ip' => $peer_ip_addr,
			'http_useragent' => $CGI{'USER-AGENT'},
		},
	);
	my $model_name = LDLNA::Devices::get_modelname_by_devicetype($peer_ip_addr, 'urn:schemas-upnp-org:device:MediaRenderer:1');
	LDLNA::Log::log('ModelName for '.$peer_ip_addr.' is '.$model_name.'.', 2, 'httpgeneric');

	#
	# HANDLING DIFFERENT KIND OF REQUESTS
	#
	if ($ENV{'OBJECT'} eq '/ServerDesc.xml') # delivering ServerDescription XML
	{
		my $xml = LDLNA::HTTPXML::get_serverdescription($CGI{'USER-AGENT'});
		my @additional_header = (
			'Content-Type: text/xml; charset=utf8',
			'Content-Length: '.length($xml),
		);
		$response = http_header({
			'statuscode' => 200,
			'additional_header' => \@additional_header,
		});
		$response .= $xml;
	}
	elsif ($ENV{'OBJECT'} eq '/ContentDirectory1.xml') # delivering ContentDirectory XML
	{
		my $xml = LDLNA::HTTPXML::get_contentdirectory();
		my @additional_header = (
			'Content-Type: text/xml; charset=utf8',
			'Content-Length: '.length($xml),
		);
		$response = http_header({
			'statuscode' => 200,
			'additional_header' => \@additional_header,
		});
		$response .= $xml;
	}
	elsif ($ENV{'OBJECT'} eq '/ConnectionManager1.xml') # delivering ConnectionManager XML
	{
		my $xml = LDLNA::HTTPXML::get_connectionmanager();
		my @additional_header = (
			'Content-Type: text/xml; charset=utf8',
			'Content-Length: '.length($xml),
		);
		$response = http_header({
			'statuscode' => 200,
			'additional_header' => \@additional_header,
		});
		$response .= $xml;
	}
	elsif ($ENV{'OBJECT'} eq '/upnp/event/ContentDirectory1' || $ENV{'OBJECT'} eq '/upnp/event/ConnectionManager1')
	{
		my $response_content = '';
		$response_content = '<html><body><h1>200 OK</h1></body></html>' if $ENV{'METHOD'} eq 'UNSUBSCRIBE';

		my @additional_header = (
			'Content-Length: '.length($response_content),
			'SID: '.$CONFIG{'UUID'},
			'Timeout: Second-'.$CONFIG{'CACHE_CONTROL'},
		);
		$response = http_header({
			'statuscode' => 200,
			'additional_header' => \@additional_header,
		});
		$response .= $response_content;
	}
	elsif ($ENV{'OBJECT'} eq '/upnp/control/ContentDirectory1') # handling Directory Listings
	{
		$response = ctrl_content_directory_1($post_xml, $CGI{'SOAPACTION'}, $peer_ip_addr, $CGI{'USER-AGENT'});
	}
#	elsif ($ENV{'OBJECT'} eq '/upnp/control/ConnectionManager1')
#	{
#	}
	elsif ($ENV{'OBJECT'} =~ /^\/media\/(.*)$/) # handling media streaming
	{
         
		stream_media($1, $ENV{'METHOD'}, \%CGI, $FH, $model_name, $peer_ip_addr, $CGI{'USER-AGENT'});
	}
	elsif ($ENV{'OBJECT'} =~ /^\/preview\/(.*)$/) # handling media thumbnails
	{
		$response = preview_media($1);
	}
	elsif ($ENV{'OBJECT'} =~ /^\/icons\/(.*)$/) # handling lombix dlna logo
	{
		$response = logo($1);
	}
	else # NOT supported request
	{
		LDLNA::Log::log('Request '.$ENV{'METHOD'}.' '.$ENV{'OBJECT'}.' from '.$peer_ip_addr.' NOT supported yet.', 2, 'httpgeneric');
		$response = http_header({
			'statuscode' => 501,
			'content_type' => 'text/plain',
		});
	}

	if (defined($response))
	{
		print $FH $response;
		close($FH);
	}
	return 1;
}

sub http_header
{
	my $params = shift;

	my %HTTP_CODES = (
		200 => 'OK',
		206 => 'Partial Content',
		400 => 'Bad request',
		403 => 'Forbidden',
		404 => 'Not found',
		406 => 'Not acceptable',
		501 => 'Not implemented',
	);

	my @response = ();
	push(@response, "HTTP/1.1 ".$$params{'statuscode'}." ".$HTTP_CODES{$$params{'statuscode'}}); # TODO (maybe) differ between http protocol versions
	push(@response, "Server: ".$CONFIG{'OS'}."/".$CONFIG{'OS_VERSION'}.", UPnP/1.0, ".$CONFIG{'PROGRAM_NAME'}."/".LDLNA::Config::print_version());
	push(@response, "Content-Type: ".$params->{'content_type'}) if $params->{'content_type'};
	push(@response, "Content-Length: ".$params->{'content_length'}) if $params->{'content_length'};
	push(@response, "Date: ".LDLNA::Utils::http_date());
#	push(@response, "Last-Modified: ".LDLNA::Utils::http_date());
	if (defined($$params{'additional_header'}))
	{
		foreach my $header (@{$$params{'additional_header'}})
		{
			push(@response, $header);
		}
	}
	push(@response, 'Cache-Control: no-cache');
	push(@response, 'Connection: close');

	LDLNA::Log::log("HTTP Response Header:\n\t".join("\n\t",@response), 3, $$params{'log'}) if defined($$params{'log'});
	return join("\r\n", @response)."\r\n\r\n";
}

sub ctrl_content_directory_1
{
	my $xml = shift;
	my $action = shift;
	my $peer_ip_addr = shift;
	my $user_agent = shift;


	my $response_xml = undef;

	LDLNA::Log::log("Function LDLNA::HTTPServer::ctrl_content_directory_1 called", 3, 'httpdir');

	if ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"')
	{
		my ($object_id, $starting_index, $requested_count, $filter, $browse_flag) = 0;
		# determine which 'Browse' element was used
		if (defined($xml->{'s:Body'}->{'ns0:Browse'}->{'ObjectID'})) # coherence seems to use this one
		{
			$object_id = $xml->{'s:Body'}->{'ns0:Browse'}->{'ObjectID'};
			$starting_index = $xml->{'s:Body'}->{'ns0:Browse'}->{'StartingIndex'};
			$requested_count = $xml->{'s:Body'}->{'ns0:Browse'}->{'RequestedCount'};
			$browse_flag = $xml->{'s:Body'}->{'ns0:Browse'}->{'BrowseFlag'};
			$filter = $xml->{'s:Body'}->{'ns0:Browse'}->{'Filter'};
		}
		elsif (defined($xml->{'s:Body'}->{'u:Browse'}->{'ObjectID'}))
		{
			$object_id = $xml->{'s:Body'}->{'u:Browse'}->{'ObjectID'};
			$starting_index = $xml->{'s:Body'}->{'u:Browse'}->{'StartingIndex'};
			$requested_count = $xml->{'s:Body'}->{'u:Browse'}->{'RequestedCount'};
			$browse_flag = $xml->{'s:Body'}->{'u:Browse'}->{'BrowseFlag'};
			$filter = $xml->{'s:Body'}->{'u:Browse'}->{'Filter'};
		}
		elsif (defined($xml->{'SOAP-ENV:Body'}->{'m:Browse'}->{'ObjectID'}->{'content'})) # and windows media player this one
		{
			$object_id = $xml->{'SOAP-ENV:Body'}->{'m:Browse'}->{'ObjectID'}->{'content'};
			$starting_index = $xml->{'SOAP-ENV:Body'}->{'m:Browse'}->{'StartingIndex'}->{'content'};
			$requested_count = $xml->{'SOAP-ENV:Body'}->{'m:Browse'}->{'RequestedCount'}->{'content'};
			$browse_flag = $xml->{'SOAP-ENV:Body'}->{'m:Browse'}->{'BrowseFlag'}->{'content'};
			$filter = $xml->{'SOAP-ENV:Body'}->{'m:Browse'}->{'Filter'}->{'content'};
		}
		else
		{
			LDLNA::Log::log('Unable to find (a known) ObjectID in XML (POSTDATA).', 1, 'httpdir');
			return http_header({
				'statuscode' => 501,
				'content_type' => 'text/plain',
			});
		}

		#
		# validate BrowseFlag
		#
		my @browsefilters = split(',', $filter) if length($filter) > 0;
		if ($browse_flag eq 'BrowseMetadata')
		{
			if (grep(/^\@parentID$/, @browsefilters))
			{
				@browsefilters = ('@id', '@parentID', '@childCount', '@restricted', 'dc:title', 'upnp:class');

				# set object_id to parentid
				LDLNA::Log::log('BrowserMetadata with parentID , requested for: '.$object_id.'.', 3, 'httpdir');			
				$object_id = LDLNA::Database::directories_get_parent($object_id);
				LDLNA::Log::log('BrowserMetadata with parentID , answered : '.$object_id.'.', 3, 'httpdir');
			}
		}
		elsif ($browse_flag eq 'BrowseDirectChildren')
		{
			if ($browsefilters[0] eq '*')
			{
				@browsefilters = ('@id', '@parentID', '@childCount', '@restricted', 'dc:title', 'upnp:class', 'res@bitrate', 'res@duration');
			}
		}
		else
		{
			LDLNA::Log::log('BrowseFlag: '.$browse_flag.' is NOT supported yet.', 2, 'httpdir');
			return http_header({
				'statuscode' => 501,
				'content_type' => 'text/plain',
			});
		}

		LDLNA::Log::log('Starting to handle Directory Listing request for: '.$object_id.'.', 3, 'httpdir');
		LDLNA::Log::log('StartingIndex: '.$starting_index.'.', 3, 'httpdir');
		LDLNA::Log::log('RequestedCount: '.$requested_count.'.', 3, 'httpdir');
		LDLNA::Log::log('BrowseFlag: '.$browse_flag.'.', 3, 'httpdir');
		LDLNA::Log::log('Filter: '.join(', ', @browsefilters).'.', 3, 'httpdir');

		$requested_count = 10 if $requested_count == 0; # if client asks for 0 items, we should return the 'default' amount (in our case 10)


		if ($object_id =~ /^\d+$/)
		{
			LDLNA::Log::log('Received numeric Directory Listing request for: '.$object_id.'.', 2, 'httpdir');

			#
			# get the subdirectories for the object_id requested
			#
			my @dire_elements = ();
			LDLNA::Database::directories_subdirectories_by_id( $object_id, $starting_index, $requested_count, \@dire_elements);

			#
			# get the full amount of subdirectories for the object_id requested
			#
			my $amount_directories = LDLNA::Database::get_amount_subdirectories_by_id( $object_id);

			$requested_count = $requested_count - scalar(@dire_elements); # amount of @dire_elements is already in answer
			if ($starting_index >= $amount_directories)
			{
				$starting_index = $starting_index - $amount_directories;
			}

			#
			# get the files for the directory requested
			#
			my @file_elements = ();
			LDLNA::Database::get_subfiles_by_id( $object_id, $starting_index, $requested_count, \@file_elements);

			#
			# get the full amount of files in the directory requested
			#
			my $amount_files = LDLNA::Database::get_amount_subfiles_by_id( $object_id);

			#
			# build the http response
			#
			$response_xml .= LDLNA::HTTPXML::get_browseresponse_header();

			foreach my $directory (@dire_elements)
			{
				$response_xml .= LDLNA::HTTPXML::get_browseresponse_directory(
					$directory->{ID},
					$directory->{NAME},
					\@browsefilters
				);
			}

			foreach my $file (@file_elements)
			{
				$response_xml .= LDLNA::HTTPXML::get_browseresponse_item($file->{ID}, \@browsefilters,  $peer_ip_addr, $user_agent);
			}

			my $elements_in_listing = scalar(@dire_elements) + scalar(@file_elements);
			my $elements_in_directory = $amount_directories + $amount_files;

			$response_xml .= LDLNA::HTTPXML::get_browseresponse_footer($elements_in_listing, $elements_in_directory);
			LDLNA::Log::log('Done preparing answer for numeric Directory Listing request for: '.$object_id.'.', 3, 'httpdir');
		}
		elsif ($object_id =~ /^(\w)\_(\w)\_{0,1}(\d*)\_{0,1}(\d*)/)
		{
			LDLNA::Log::log('Received SpecificView Directory Listing request for: '.$object_id.'.', 2, 'httpdir');

			my $media_type = $1;
			my $group_type = $2;
			my $group_id = $3;
			my $item_id = $4;

			unless (LDLNA::SpecificViews::supported_request($media_type, $group_type))
			{
				LDLNA::Log::log('SpecificView: '.$media_type.'_'.$group_type.' is NOT supported yet.', 2, 'httpdir');
				return http_header({
					'statuscode' => 501,
					'content_type' => 'text/plain',
				});
			}

			if (length($group_id) == 0)
			{
				my @group_elements = ();
				LDLNA::SpecificViews::get_groups( $media_type, $group_type, $starting_index, $requested_count, \@group_elements);
				my $amount_groups = LDLNA::SpecificViews::get_amount_of_groups( $media_type, $group_type);

				$response_xml .= LDLNA::HTTPXML::get_browseresponse_header();
				foreach my $group (@group_elements)
				{
					$response_xml .= LDLNA::HTTPXML::get_browseresponse_group_specific(
						$group->{ID},
						$media_type,
						$group_type,
						$group->{NAME},
						\@browsefilters
					);
				}
				$response_xml .= LDLNA::HTTPXML::get_browseresponse_footer(scalar(@group_elements), $amount_groups);
			}
			elsif (length($group_id) > 0 && length($item_id) == 0)
			{
				$group_id = LDLNA::Utils::remove_leading_char($group_id, '0');

				my @item_elements = ();
				LDLNA::SpecificViews::get_items( $media_type, $group_type, $group_id, $starting_index, $requested_count, \@item_elements);
				my $amount_items = LDLNA::SpecificViews::get_amount_of_items( $media_type, $group_type, $group_id);

				$response_xml .= LDLNA::HTTPXML::get_browseresponse_header();
				foreach my $item (@item_elements)
				{
					$response_xml .= LDLNA::HTTPXML::get_browseresponse_item_specific(
						$item->{ID},
						$media_type,
						$group_type,
						$group_id,
						\@browsefilters,
						$peer_ip_addr,
						$user_agent,
					);
				}
				$response_xml .= LDLNA::HTTPXML::get_browseresponse_footer(scalar(@item_elements), $amount_items);
			}
			else
			{
				LDLNA::Log::log('SpecificView: Unable to understand request for ObjectID '.$object_id.'.', 2, 'httpdir');
				return http_header({
					'statuscode' => 501,
					'content_type' => 'text/plain',
				});
			}
		}
	}
	elsif ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#GetSearchCapabilities"')
	{
		$response_xml .= '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">';
		$response_xml .= '<s:Body>';
		$response_xml .= '<u:GetSearchCapabilitiesResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">';
		$response_xml .= '<SearchCaps></SearchCaps>';
		$response_xml .= '</u:GetSearchCapabilitiesResponse>';
		$response_xml .= '</s:Body>';
		$response_xml .= '</s:Envelope>';
	}
	elsif ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#GetSortCapabilities"')
	{
		$response_xml .= '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">';
		$response_xml .= '<s:Body>';
		$response_xml .= '<u:GetSortCapabilitiesResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">';
		$response_xml .= '<SortCaps></SortCaps>';
		$response_xml .= '</u:GetSortCapabilitiesResponse>';
		$response_xml .= '</s:Body>';
		$response_xml .= '</s:Envelope>';
	}
	elsif ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#GetSystemUpdateID"')
	{
		$response_xml .= '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">';
		$response_xml .= '<s:Body>';
		$response_xml .= '<u:GetSystemUpdateIDResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">';
		$response_xml .= '<Id>0</Id>';
		$response_xml .= '</u:GetSystemUpdateIDResponse>';
		$response_xml .= '</s:Body>';
		$response_xml .= '</s:Envelope>';
	}
	# OLD CODE
#	elsif ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#X_GetObjectIDfromIndex"')
#	{
#		my $media_type = '';
#		my $sort_type = '';
#		if ($xml->{'s:Body'}->{'u:X_GetObjectIDfromIndex'}->{'CategoryType'} == 14)
#		{
#			$media_type = 'I';
#			$sort_type = 'F';
#		}
#		elsif ($xml->{'s:Body'}->{'u:X_GetObjectIDfromIndex'}->{'CategoryType'} == 22)
#		{
#			$media_type = 'A';
#			$sort_type = 'F';
#		}
#		elsif ($xml->{'s:Body'}->{'u:X_GetObjectIDfromIndex'}->{'CategoryType'} == 32)
#		{
#			$media_type = 'V';
#			$sort_type = 'F';
#		}
#		LDLNA::Log::log('Getting object for '.$media_type.'_'.$sort_type.'.', 2, 'httpdir');
#
#		my $index = $xml->{'s:Body'}->{'u:X_GetObjectIDfromIndex'}->{'Index'};
#
#		my $content_type_obj = $content->get_content_type($media_type, $sort_type);
#		my $i = 0;
#		my @groups = @{$content_type_obj->content_groups()};
#		while ($index >= $groups[$i]->content_items_amount())
#		{
#			$index -= $groups[$i]->content_items_amount();
#			$i++;
#		}
#		my $content_item_obj = $groups[$i]->content_items()->[$index];
#
#		$response = http_header({
#			'statuscode' => 200,
#		});
#
#		$response .= '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">';
#		$response .= '<s:Body>';
#		$response .= '<u:X_GetObjectIDfromIndexResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">';
#		$response .= '<ObjectID>'.$media_type.'_'.$sort_type.'_'.$groups[$i]->beautiful_id().'_'.$content_item_obj->beautiful_id().'</ObjectID>';
#		$response .= '</u:X_GetObjectIDfromIndexResponse>';
#		$response .= '</s:Body>';
#		$response .= '</s:Envelope>';
#	}
	# TODO X_GetIndexfromRID (i think it might be the question, to which item the tv should jump ... but currently i don't understand the question (<RID></RID>)
	elsif ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#X_GetIndexfromRID"')
	{
		$response_xml .= '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">';
		$response_xml .= '<s:Body>';
		$response_xml .= '<u:X_GetIndexfromRIDResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">';
		$response_xml .= '<Index>0</Index>'; # we are setting it to 0 - so take the first item in the list to be active
		$response_xml .= '</u:X_GetIndexfromRIDResponse>';
		$response_xml .= '</s:Body>';
		$response_xml .= '</s:Envelope>';
	}
	elsif ($action eq '"urn:schemas-upnp-org:service:ContentDirectory:1#X_SetBookmark"')
	{
		LDLNA::Log::log('Handling X_SetBookmark request.', 2, 'httpdir');
		if (defined($xml->{'s:Body'}->{'u:Browse'}->{'ObjectID'}) && defined($xml->{'s:Body'}->{'u:Browse'}->{'PosSecond'}))
		{
			my $device_ip = LDLNA::Database::device_ip_get_id($peer_ip_addr);

			if (defined($device_ip->{ID}))
			{
				my $device_bm_posseconds = LDLNA::Database::device_bm_get_posseconds($xml->{'s:Body'}->{'u:Browse'}->{'ObjectID'}, $device_ip->{ID});
				if (defined($device_bm_posseconds))
				{
					LDLNA::Database::device_bm_update_posseconds($xml->{'s:Body'}->{'u:Browse'}->{'PosSecond'}, $xml->{'s:Body'}->{'u:Browse'}->{'ObjectID'}, $device_ip->{ID});
				}
				else
				{
					LDLNA::Database::device_bm_insert_posseconds($xml->{'s:Body'}->{'u:Browse'}->{'ObjectID'}, $device_ip->{ID}, $xml->{'s:Body'}->{'u:Browse'}->{'PosSecond'});
				}

				$response_xml .= '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">';
				$response_xml .= '<s:Body>';
				$response_xml .= '<u:X_SetBookmarkResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">';
				$response_xml .= '</u:X_SetBookmarkResponse>';
				$response_xml .= '</s:Body>';
				$response_xml .= '</s:Envelope>';
			}
			else
			{
				LDLNA::Log::log('Unable to find matching DEVICE_IP database entry.', 2, 'httpdir');
				return http_header({
					'statuscode' => 501,
					'content_type' => 'text/plain',
				});
			}
		}
		else
		{
			LDLNA::Log::log('Missing ObjectID or PosSecond parameter.', 2, 'httpdir');
			return http_header({
				'statuscode' => 501,
				'content_type' => 'text/plain',
			});
		}
	}
	else
	{
		LDLNA::Log::log('Action: '.$action.' is NOT supported yet.', 2, 'httpdir');
		return http_header({
			'statuscode' => 501,
			'content_type' => 'text/plain',
		});
	}

	#
	# RETURN THE ANSWER
	#
	my $response = undef;
	if (defined($response_xml))
	{
		$response = http_header({
			'statuscode' => 200,
			'log' => 'httpdir',
			'content_length' => length($response_xml),
			'content_type' => 'text/xml; charset=utf8',
		});
		$response .= $response_xml;
		LDLNA::Log::log('Response: '.$response, 3, 'httpdir');
	}
	else
	{
		LDLNA::Log::log('No Response.', 2, 'httpdir');
		$response = http_header({
			'statuscode' => 501,
			'content_type' => 'text/plain',
		});
	}
	return $response;
}



sub stream_media
{
	my $content_id = shift;
	my $method = shift;
	my $CGI = shift;
	my $FH = shift;
	my $model_name = shift;
	my $client_ip = shift;
	my $user_agent = shift;


    
	LDLNA::Log::log('ContentID: '.$content_id, 3, 'httpstream');
	if ($content_id =~ /^(\d+)/)
	{
		my $id = $1;
        
		LDLNA::Log::log('ID: '.$id, 3, 'httpstream');

		#
		# getting information from database
		#
		my @records = LDLNA::Database::get_records_by("FILES",{ID => $id});
        my $item = $records[0];
		#
		#

		#
		# sanity checks
		#
        
		unless (defined($item->{FULLNAME}))
		{
			LDLNA::Log::log('Content with ID '.$id.' NOT found (in media library).', 1, 'httpstream');
			print $FH http_header({
				'statuscode' => 404,
				'content_type' => 'text/plain',
				'log' => 'httpstream',
			});
			return;
		}

		if (!$item->{EXTERNAL} && !-f $item->{FULLNAME})
		{
			LDLNA::Log::log('Content with ID '.$id.' NOT found (on filesystem): '.$item->{FULLNAME}.'.', 1, 'httpstream');
			print $FH http_header({
				'statuscode' => 404,
				'content_type' => 'text/plain',
				'log' => 'httpstream',
			});
			return;
		}

		if ($item->{EXTERNAL} && !LDLNA::Media::is_supported_stream($item->{FULLNAME}) && !-x $item->{FULLNAME})
		{
			LDLNA::Log::log('Content with ID '.$id.' is a SCRIPT but NOT executable: '.$item->{FULLNAME}.'.', 1, 'httpstream');
			print $FH http_header({
				'statuscode' => 404,
				'content_type' => 'text/plain',
				'log' => 'httpstream',
			});
			return;
		}

		#
		# for streaming relevant code starts here
		#
        
        
		my @additional_header = ();
		push(@additional_header, 'Content-Type: '.LDLNA::Media::get_mimetype_by_modelname($item->{MIME_TYPE}, $model_name));
		push(@additional_header, 'Content-Length: '.$item->{SIZE}) if !$item->{EXTERNAL};
		push(@additional_header, 'Content-Disposition: attachment; filename="'.$item->{NAME}.'"') if !$item->{EXTERNAL};
		push(@additional_header, 'Accept-Ranges: bytes');

		# Streaming of content is NOT working with SAMSUNG without this response header
		if (defined($$CGI{'GETCONTENTFEATURES.DLNA.ORG'}))
		{
			if ($$CGI{'GETCONTENTFEATURES.DLNA.ORG'} == 1)
		{
				push(@additional_header, 'contentFeatures.dlna.org: '.LDLNA::Media::get_dlnacontentfeatures($item));
			}
			else
			{
				LDLNA::Log::log('Invalid contentFeatures.dlna.org:'.$$CGI{'GETCONTENTFEATURES.DLNA.ORG'}.'.', 1, 'httpstream');
				print $FH http_header({
					'statuscode' => 400,
					'content_type' => 'text/plain',
				});
			}
		}


		# duration
		if (defined($$CGI{'GETMEDIAINFO.SEC'}))
		{
			if ($$CGI{'GETMEDIAINFO.SEC'} == 1)
			{
				if ($item->{TYPE} eq 'video' || $item->{TYPE} eq 'audio')
				{
					push(@additional_header, 'MediaInfo.sec: SEC_Duration='.$item->{DURATION}.'000;'); # in milliseconds
					unless (grep(/^contentFeatures.dlna.org:/, @additional_header))
					{
						push(@additional_header, 'contentFeatures.dlna.org: '.LDLNA::Media::get_dlnacontentfeatures($item));
					}
				}
			}
			else
			{
				LDLNA::Log::log('Invalid getMediaInfo.sec:'.$$CGI{'GETMEDIAINFO.SEC'}.'.', 1, 'httpstream');
				print $FH http_header({
					'statuscode' => 400,
					'content_type' => 'text/plain',
				});
			}
		}
    
		if ($method eq 'HEAD') # handling HEAD requests
		{
			LDLNA::Log::log('Delivering content information (HEAD Request) for: '.$item->{NAME}.'.', 1, 'httpstream');

			print $FH http_header({
				'statuscode' => 200,
				'additional_header' => \@additional_header,
				'log' => 'httpstream',
			});
		}
		elsif ($method eq 'GET') # handling GET requests
		{
			# for clients, which are not sending the Streaming value for the transferMode.dlna.org parameter
			# we set it, because they seem to ignore it
			if (defined($$CGI{'USER-AGENT'}))
			{
                
				if (
					$$CGI{'USER-AGENT'} =~ /^foobar2000/ || # since foobar2000 is NOT sending any TRANSFERMODE.DLNA.ORG param
					$$CGI{'USER-AGENT'} =~ /^vlc/i || # since vlc is NOT sending any TRANSFERMODE.DLNA.ORG param
					$$CGI{'USER-AGENT'} =~ /^stagefright/ || # since UPnPlay is NOT sending any TRANSFERMODE.DLNA.ORG param
					$$CGI{'USER-AGENT'} =~ /^gvfs/ || # since Totem Movie Player is NOT sending any TRANSFERMODE.DLNA.ORG param
                    $$CGI{'USER-AGENT'} =~ /^Mozilla/ || # In order to allow some tests from the Browser directly
                    $$CGI{'USER-AGENT'} =~ /^Dalvik/  || # Some android stuff ( to see the images )
					$$CGI{'USER-AGENT'} =~ /^\(null\)/
					)
				{
					$$CGI{'TRANSFERMODE.DLNA.ORG'} = 'Streaming';
				}
			}

			# transferMode handling
			if (defined($$CGI{'TRANSFERMODE.DLNA.ORG'}))
			{
				if ($$CGI{'TRANSFERMODE.DLNA.ORG'} eq 'Streaming') # for immediate rendering of audio or video content
				{
                    
					push(@additional_header, 'transferMode.dlna.org: Streaming');

					my $statuscode = 200;
					my ($lowrange, $highrange) = 0;
					if (
							defined($$CGI{'RANGE'}) &&						# if RANGE is defined as HTTP header
							$$CGI{'RANGE'} =~ /^bytes=(\d+)-(\d*)$/ &&		# if RANGE looks like
							!$item->{EXTERNAL} 						# if FILE is not external
						)
					{
						LDLNA::Log::log('Delivering content for: '.$item->{FULLNAME}.' with RANGE Request.', 1, 'httpstream');
						my $statuscode = 206;

						$lowrange = int($1);
						$highrange = $2 ? int($2) : 0;
						$highrange = $item->{SIZE}-1 if $highrange == 0;
						$highrange = $item->{SIZE}-1 if ($highrange >= $item->{SIZE});

						my $bytes_to_ship = $highrange - $lowrange + 1;

						$additional_header[1] = 'Content-Length: '.$bytes_to_ship; # we need to change the Content-Length
						push(@additional_header, 'Content-Range: bytes '.$lowrange.'-'.$highrange.'/'.$item->{SIZE});
					}

					#
					# sending the response
					#
					if (!$item->{EXTERNAL} ) # file on disk or TRANSFERMODE is NOT required
					{
                        if ($item->{TYPE} eq 'video')
						  {
							my ($basicfilename) = $item->{"NAME"} =~ /^(.+)\.(avi|mp4)$/;  # This means we will only handle subtitles for avi and mp4
							my $subtitle = File::Spec->catdir($item->{"PATH"},$basicfilename).".srt";
							if (-f $subtitle)
							 {
								my $cmd;
								if    ( $item->{"NAME"} =~ /mp4$/ ) { $cmd = "mencoder -really-quiet -oac mp3lame -ovc lavc -lavcopts vcodec=mpeg4 -sub $subtitle -subfont-text-scale 3.0 -subpos 95  -o - ".$item->{"FULLNAME"}; }
								elsif ( $item->{"NAME"} =~ /avi$/ ) { $cmd = "mencoder -really-quiet -oac copy -ovc raw -sub $subtitle -subfont-text-scale 3.0 -subpos 95  -o - ".$item->{"FULLNAME"}; }
								open(ITEM, '-|', $cmd);
								binmode(ITEM); 
							 }
							else {
							   sysopen(ITEM, $item->{FULLNAME}, O_RDONLY);
						       sysseek(ITEM, $lowrange, 0) if $lowrange;	
					         }
						  }
						 else { 
						   sysopen(ITEM, $item->{FULLNAME}, O_RDONLY);
						   sysseek(ITEM, $lowrange, 0) if $lowrange;
						 }
					}
					else # streams, scripts, 
					{
						my $command = '';
						if (LDLNA::Media::is_supported_stream($item->{FULLNAME})) # if it is a supported stream
						{
                            
                            if ($item->{FULLNAME} =~ /^rtmp/) { $command = " $CONFIG{'RTMPDUMP_BIN'} -r $item->{FULLNAME} -q -v 2>/dev/null"; }
                            else {$command = "$CONFIG{'FFMPEG_BIN'} -i $item->{FULLNAME} -vcodec copy -acodec copy -f avi pipe:1  2>/dev/null"; }
						}

                        
						open(ITEM, '-|', $command);
						binmode(ITEM);
						@additional_header = map { /^(Content-Length|Accept-Ranges):/i ? () : $_ } @additional_header; # delete some header
					}
					
					
					print $FH http_header({
						'statuscode' => $statuscode,
						'additional_header' => \@additional_header,
						'log' => 'httpstream',
					});
					my $buf = undef;
					while (sysread(ITEM, $buf, $CONFIG{'BUFFER_SIZE'}))
					{
						LDLNA::Log::log('Adding '.bytes::length($buf).' bytes to Streaming connection.', 3, 'httpstream');
						print $FH $buf or return 1;
					}
					close(ITEM);
					return 1;
				}
				elsif ($$CGI{'TRANSFERMODE.DLNA.ORG'} eq 'Interactive') # for immediate rendering of images or playlist files
				{
					LDLNA::Log::log('Delivering (Interactive) content for: '.$item->{FULLNAME}.'.', 1, 'httpstream');
					push(@additional_header, 'transferMode.dlna.org: Interactive');

					# Delivering interactive content as a whole
					print $FH http_header({
						'statuscode' => 200,
						'additional_header' => \@additional_header,
					});
					sysopen(FILE, $item->{FULLNAME}, O_RDONLY);
					print $FH <FILE>;
					close(FILE);
				}
				else # unknown TRANSFERMODE.DLNA.ORG is set
				{
					LDLNA::Log::log('Transfermode '.$$CGI{'TRANSFERMODE.DLNA.ORG'}.' for Streaming Items is NOT supported yet.', 2, 'httpstream');
					print $FH http_header({
						'statuscode' => 501,
						'content_type' => 'text/plain',
					});
				}
			}
			else # no TRANSFERMODE.DLNA.ORG is set
			{
				LDLNA::Log::log('Delivering content information (no Transfermode) for: '.$item->{FULLNAME}.'.', 1, 'httpstream');
				print $FH http_header({
					'statuscode' => 200,
					'additional_header' => \@additional_header,
					'log' => 'httpstream',
				});
			}
		}
		else # not implemented HTTP method
		{
			LDLNA::Log::log('HTTP Method '.$method.' for Streaming Items is NOT supported yet.', 2, 'httpstream');
			print $FH http_header({
				'statuscode' => 501,
				'content_type' => 'text/plain',
				'log' => 'httpstream',
			});
		}
	}
	else
	{
		LDLNA::Log::log('ContentID '.$content_id.' for Streaming Items is NOT supported yet.', 2, 'httpstream');
		print $FH http_header({
			'statuscode' => 501,
			'content_type' => 'text/plain',
			'log' => 'httpstream',
		});
	}
}

sub preview_media
{
	my $content_id = shift;

	if ($content_id =~ /^(\d+)\./)
	{
		my $id = $1;

	
		my @records = LDLNA::Database::get_records_by("FILES", {ID => $id});
                my $item_info = $records[0];
		if (defined($item_info->{FULLNAME}))
		{
			unless (-f $item_info->{FULLNAME})
			{
				LDLNA::Log::log('Delivering preview for NON EXISTING Item is NOT supported.', 2, 'httpstream');
				return http_header({
					'statuscode' => 404,
					'content_type' => 'text/plain',
				});
			}

			if ($item_info->{EXTERNAL})
			{
				LDLNA::Log::log('Delivering preview for EXTERNAL Item is NOT supported yet.', 2, 'httpstream');
				return http_header({
					'statuscode' => 501,
					'content_type' => 'text/plain',
				});
			}

			if ($item_info->{TYPE} eq 'audio')
			{
				LDLNA::Log::log('Delivering preview for Audio Item is NOT supported yet.', 2, 'httpstream');
				return http_header({
					'statuscode' => 501,
					'content_type' => 'text/plain',
				});
			}

			LDLNA::Log::log('Delivering preview for: '.$item_info->{FULLNAME}.'.', 2, 'httpstream');

			my $path = $item_info->{FULLNAME};
			if ($item_info->{TYPE} eq 'video')
			{
			 # There is a more clean and portable way to create path in perl, to review                                                                                                                                                 
			 $path = dirname($item_info->{FULLNAME})."/.thumbnails/".$item_info->{ID}.".jpg";                                                                                                                                                 
 			}

			# image scaling stuff
			GD::Image->trueColor(1);
			my $image = GD::Image->new($path);
			unless ($image)
			{
				LDLNA::Log::log('Problem creating GD::Image object for Item Preview.', 2, 'httpstream');
				return http_header({
					'statuscode' => 501,
					'content_type' => 'text/plain',
				});
			}
			my $height = $image->height / ($image->width/160);
			my $preview = GD::Image->new(160, $height);
			$preview->copyResampled($image, 0, 0, 0, 0, 160, $height, $image->width, $image->height);


			# the response itself
			my $response = http_header({
				'statuscode' => 200,
				'content_type' => 'image/jpeg',
			});
			$response .= $preview->jpeg();
			$response .= "\r\n";

			return $response;
		}
		else
		{
			LDLNA::Log::log('ContentID '.$id.' NOT found.', 2, 'httpstream');
			return http_header({
				'statuscode' => 404,
				'content_type' => 'text/plain',
			});
		}
	}
	else
	{
		LDLNA::Log::log('ContentID '.$content_id.' for Item Preview is NOT supported yet.', 2, 'httpstream');
		return http_header({
			'statuscode' => 404,
			'content_type' => 'text/plain',
		});
	}
}

sub logo
{
	my ($size, $type) = split('/', shift);
	$type = lc($1) if ($type =~ /\.(\w{3,4})$/);

	my $response = '';
	if ($type =~ /^(jpeg|png)$/)
	{
		LDLNA::Log::log('Delivering Logo in format '.$type.' and with '.$size.'x'.$size.' pixels.', 2, 'httpgeneric');

		GD::Image->trueColor(1);
		my $image = GD::Image->new('LDLNA/logo.png');
		my $preview = GD::Image->new($size, $size);

		# all black areas of the image should be transparent
		my $black = $preview->colorAllocate(0,0,0);
		$preview->transparent($black);

		$preview->copyResampled($image, 0, 0, 0, 0, $size, $size, $image->width, $image->height);

		my @additional_header = ();
		$additional_header[0] = 'Content-Type: image/jpeg' if ($type eq 'jpeg');
		$additional_header[0] = 'Content-Type: image/png' if ($type eq 'png');

		$response = http_header({
			'statuscode' => 200,
			'additional_header' => \@additional_header,
		});
		$response .= $preview->jpeg() if ($type eq 'jpeg');
		$response .= $preview->png() if ($type eq 'png');
		$response .= "\r\n";
	}
	else
	{
		LDLNA::Log::log('Unknown Logo format '.$type.'.', 2, 'httpgeneric');
		$response = http_header({
			'statuscode' => 404,
			'content_type' => 'text/plain',
		});
	}

	return $response;
}

1;
