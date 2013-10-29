package LDLNA::ContentLibrary;
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

use Linux::Inotify2;
use DBI;
use Date::Format;
use File::Basename;
use File::Glob qw(bsd_glob);
use File::MimeInfo;

use LDLNA::Config;
use LDLNA::Database;
use LDLNA::Log;
use LDLNA::Media;
use LDLNA::Utils;


our $inotify;

sub index_directories_thread_external
{
                LDLNA::Log::log('Starting LDLNA::ContentLibrary::index_directories_thread_external().', 1, 'library');
                my $timestamp_start = time();
		foreach my $external (@{$CONFIG{'EXTERNALS'}})
		{
			add_file_to_db(
				
				{
					'element' => $external->{'command'} || $external->{'streamurl'},
					'media_type' => $external->{'type'},
					'mime_type' => undef, # need to determine
					'element_basename' => $external->{'name'},
					'element_dirname' => undef, # set the directory to nothing - no parent
					'external' => 1,
					'root' => 1,
				},
			);
		}
                my $timestamp_end = time();
                my $duration = $timestamp_end - $timestamp_start;
	        LDLNA::Log::log('Indexing configured external media  '.$duration.' seconds.', 1, 'library');
		                     
    threads->exit();
}

sub index_directories_thread
{
 

        $inotify = new Linux::Inotify2 or die "unable to create new inotify object: $!";
	LDLNA::Log::log('Starting LDLNA::ContentLibrary::index_directories_thread().', 1, 'library');

		my $timestamp_start = time();
		foreach my $directory (@{$CONFIG{'DIRECTORIES'}}) 
		{
				
		   process_directory(  $directory->{'path'} ); 
	        }

             
		my $timestamp_end = time();

		# add our timestamp when finished
                LDLNA::Database::metadata_update_value($timestamp_end,'TIMESTAMP');

		my $duration = $timestamp_end - $timestamp_start;
		LDLNA::Log::log('Indexing configured media directories took '.$duration.' seconds.', 1, 'library');

		my ($amount, $size) = LDLNA::Database::files_get_all_size();
		LDLNA::Log::log('Configured media directories include '.$amount.' with '.LDLNA::Utils::convert_bytes($size).' of size.', 1, 'library');


1 while $inotify->poll;
	
}

sub inotify_process_directory
{
 my $e = shift;
 
    my $name = $e->fullname;
    if ( $e->IN_CREATE ) 
     {
       LDLNA::Log::log('New file included '.$e->fullname, 1, 'library');  
       process_directory( dirname($name) );
     }
    elsif ($e->IN_DELETE )
     {
      remove_nonexistant_files(); # This is brutal, if we have the name we shouldnt re-check ALL the files.
                                  # OBviously to be improved
     }
                
}

sub process_directory
{
	my $path  = shift;
	$path =~ s/\/$//;

	add_directory_to_db( $path );
	$inotify->watch($path, IN_CREATE | IN_DELETE, \&inotify_process_directory);

	$path = LDLNA::Utils::escape_brackets($path);
	LDLNA::Log::log('Globbing directory: '.LDLNA::Utils::create_filesystem_path([ $path, '*', ]).'.', 2, 'library');
	my @elements = bsd_glob(LDLNA::Utils::create_filesystem_path([ $path, '*', ]));
	foreach my $element (sort @elements)
	{
		my $element_basename = basename($element);

		if (-d "$element" && $element =~ /lost\+found$/)
		{
			LDLNA::Log::log('Skipping '.$element.' directory.', 2, 'library');
			next;
		}
		elsif (-d "$element" )
		{
			LDLNA::Log::log('Processing directory '.$element.'.', 2, 'library');
                        process_directory( $element );
                                
		}
		elsif (-f "$element" )
		{
			my ($ext) = basename($element) =~ /\.([^.]+)$/;
			next if ($ext eq "srt" or $ext eq "doc" or $ext eq "xls" or $ext eq "exe" or $ext eq "odt" or $ext eq "pdf");
			 
			my $mime_type = mimetype($element);
			LDLNA::Log::log('Processing '.$element.' with MimeType '.$mime_type.'.', 2, 'library');

			if (LDLNA::Media::is_supported_mimetype($mime_type))
			{
				    my $media_type = LDLNA::Media::return_type_by_mimetype($mime_type);
					LDLNA::Log::log('Adding '.$media_type.' element '.$element.'.', 2, 'library');

					my $fileid = add_file_to_db(
						
						{
							'element' => $element,
							'media_type' => $media_type,
							'mime_type' => $mime_type,
							'element_basename' => $element_basename,
							'element_dirname' => dirname($element),
							'external' => 0,
							'root' => 0,
						},
					);

                              
			}
			elsif (LDLNA::Media::is_supported_playlist($mime_type))
			{
				LDLNA::Log::log('Adding playlist '.$element.' as directory.', 2, 'library');
				add_directory_to_db( $element );
				my @items = LDLNA::Media::parse_playlist($element, $mime_type);
				for (my $i = 0; $i < @items; $i++)
				{
					if (LDLNA::Media::is_supported_stream($items[$i]) )
					{
						add_file_to_db(
							
							{
								'element' => $items[$i],
								'media_type' => '', # need to determine
								'mime_type' => '', # need to determine
								'element_basename' => $items[$i],
								'element_dirname' => $element, # set the directory to the playlist file itself
								'external' => 1,
								'root' => 0,
							},
						);
					}
					else
					{
						unless (LDLNA::Utils::is_path_absolute($items[$i]))
						{
							$items[$i] = LDLNA::Utils::create_filesystem_path([ dirname($element), $items[$i], ]);
						}

						if (-f $items[$i])
						{
							my $mime_type = mimetype($items[$i]);
							my $media_type = LDLNA::Media::return_type_by_mimetype($mime_type);
							add_file_to_db(
								
								{
									'element' => $items[$i],
									'media_type' => $media_type,
									'mime_type' => $mime_type,
									'element_basename' => basename($items[$i]),
									'element_dirname' => $element, # set the directory to the playlist file itself
									'external' => 0,
									'root' => 0,
								},
							);
						}
					}
				}

				# delete not (any more) configured - media files from playlists
				my @results = LDLNA::Database::get_records_by( "FILES", {PATH => $element});
				foreach my $result (@results)
				{
					unless (grep(/^$result->{NAME}$/, @items) || grep(/^$result->{FULLNAME}$/, @items))
					{
						delete_all_by_itemid( $result->{ID});
					}
				}
			}
			else
			{
				LDLNA::Log::log('Element '.$element.' skipped. Unsupported MimeType '.$mime_type.'.', 2, 'library');
			}
		}
		else
		{
			LDLNA::Log::log('Element '.$element.' skipped. Inlcuded in ExcludeList.', 2, 'library');
		}
	}
}

sub add_directory_to_db
{

	my $path = shift;
      
	

	# check if directoriy is in db
	my $results = (LDLNA::Database::get_records_by("DIRECTORIES", { PATH => $path}))[0];
	unless (defined($results->{ID}))
	{
		# add directory to database
		LDLNA::Database::directories_insert(basename($path),$path,dirname($path));
		LDLNA::Log::log('Added directory '.$path.' to ContentLibrary.', 2, 'library');
	}
}



sub add_file_to_db
{
	my $params = shift;

	my @fileinfo = ();
	$fileinfo[9] = 0;
	$fileinfo[7] = 0;
	my $file_extension = '';
	if ($$params{'external'} == 0)
	{
		@fileinfo = stat($$params{'element'});
		$file_extension = $1 if $$params{'element'} =~ /(\w{3,4})$/;
	}

	$$params{'sequence'} = 0 if !defined($$params{'sequence'});

	# check if file is in db

         my $results = (LDLNA::Database::get_records_by( "FILES", {FULLNAME => $$params{'element'}, PATH => $$params{'element_dirname'}} ))[0];
         return if (defined($results->{ID}) and  $$params{'external'} == 1); # If already there an external stream we skip.. is too costly checking all the time
         return if (defined($results->{ID}) and $$params{'external'} == 0 and ($results->{SIZE} == $fileinfo[7] and $results->{DATE} == $fileinfo[9]) );
        

         my %info = ();
         LDLNA::Media::get_media_info($$params{'element'}, \%info);
         if (defined($info{'TYPE'})) {  # Because if we cannot get the type of the file we will not bother adding it to db
       	   if (defined($results->{ID}))
	     {
		  if ( $$params{'external'} == 0 and ($results->{SIZE} != $fileinfo[7] || $results->{DATE} != $fileinfo[9]) )
		   {
			# update the datbase entry (something changed)
                        # TODO : We have here at least two updates that we could consolidate into a single one
                        LDLNA::Log::log("File: ".$$params{'element'}." has changed so we re-scan it and add to the db",1,'database');
			LDLNA::Database::files_update($results->{ID} , { DATE => $fileinfo[9], SIZE => $fileinfo[7], MIME_TYPE => $$params{'mime_type'}, TYPE => $$params{'media_type'}, SEQUENCE => $$params{'sequence'} } );
			LDLNA::Database::files_update($results->{ID}, \%info );
			LDLNA::Media::create_thumbnail($results);
		   }
	     }
	  else
	    {
	     $$params{'size'} = $fileinfo[7];
             $$params{'date'} = $fileinfo[9];
	     $$params{'file_extension'} = $file_extension;
           
	       $results = LDLNA::Database::files_insert_returning_record( $params );
	       LDLNA::Database::files_update( $results->{ID}, \%info );
               LDLNA::Media::create_thumbnail($results);		
            }
            
          # Now, a last check, if the thumbnail is not present, we create it
          unless ( -f (dirname($results->{FULLNAME}))."/.thumbnails/".$results->{ID}.".jpg" )
          {
           LDLNA::Media::create_thumbnail($results);
          }		
    }
    else {
      LDLNA::Log::log("File: ".$$params{'element'}." discarded and not added to the db",1,'database'); 
    }

	return $results->{ID};
}

sub remove_nonexistant_files
{

	LDLNA::Log::log('Started to remove non existant files.', 1, 'library');
	my @files = LDLNA::Database::files_get_non_external_files();

	foreach my $file (@files)
	{
		unless (-f "$file->{FULLNAME}")
		{
			delete_all_by_itemid( $file->{ID} );
		}
	}

	my @directories = LDLNA::Database::get_records_by("DIRECTORIES");
	foreach my $directory (@directories)
	{
		if (
			( !-d "$directory->{PATH}")  && (!-f "$directory->{PATH}")
		)
		{
			LDLNA::Database::directories_delete( $directory->{ID} );
		}
	}



	# delete not (any more) configured - directories from database
	my @rootdirs = ();
	LDLNA::Database::directories_subdirectories_by_id( 0, undef, undef, \@rootdirs);

	my @conf_directories = ();
	foreach my $directory (@{$CONFIG{'DIRECTORIES'}})
	{
	   push(@conf_directories, $directory->{'path'});
	}

	foreach my $rootdir (@rootdirs)
	{
		unless (grep(/^$rootdir->{PATH}\/*$/, @conf_directories))
		{
			delete_subitems_recursively( $rootdir->{ID});
		}
	}

	# delete not (any more) configured - external from database
	my @externals = ();
	LDLNA::Database::get_subfiles_by_id( 0, undef, undef, \@externals);

	my @conf_externals = ();
	foreach my $external (@{$CONFIG{'EXTERNALS'}})
	{
		push(@conf_externals, $external->{'name'});
	}

	foreach my $external (@externals)
	{
		unless (grep(/^$external->{NAME}$/, @conf_externals))
		{
			delete_all_by_itemid( $external->{ID});
		}
	}

	# delete external media items from database, if LOW_RESOURCE_MODE has been enabled
	if ($CONFIG{'LOW_RESOURCE_MODE'} == 1)
	{
		my @externalfiles = LDLNA::Database::files_get_external_files();
		foreach my $externalfile (@externalfiles)
		{
			delete_all_by_itemid( $externalfile->{ID});
		}
	}

	foreach my $directory (@{$CONFIG{'DIRECTORIES'}})
	{
		# delete excluded directories and their items
		foreach my $excl_directory (@{$$directory{'exclude_dirs'}})
		{
			my @directories = LDLNA::Database::get_records_by("DIRECTORIES", { NAME => $excl_directory, PATH => $directory->{'path'}.'%'});
			foreach my $dir (@directories)
			{
				delete_subitems_recursively( $dir->{ID});
			}
		}

		# delete excluded items
		foreach my $excl_items (@{$$directory{'exclude_items'}})
		{
			my @items = LDLNA::Database::get_records_by( "FILES", {NAME => $excl_items, PATH => $directory->{'path'}.'%'});
			foreach my $item (@items)
			{
				delete_all_by_itemid( $item->{ID});
			}
		}
	}
}

sub delete_all_by_itemid
{
	my $object_id = shift;

	LDLNA::Database::files_delete($object_id);

}

sub delete_subitems_recursively
{
	my $object_id = shift;

	my @subfiles = ();
	LDLNA::Database::get_subfiles_by_id( $object_id, undef, undef, \@subfiles);
	foreach my $file (@subfiles)
	{
		delete_all_by_itemid( $file->{ID});
	}

	my @subdirs = ();
	LDLNA::Database::directories_subdirectories_by_id( $object_id, undef, undef, \@subdirs);
	foreach my $directory (@subdirs)
	{
		delete_subitems_recursively( $directory->{ID});
		LDLNA::Database::directories_delete( $directory->{ID});
	}

	LDLNA::Database::directories_delete( $object_id );
}





#
# helper functions
#

# TODO make it more beautiful
sub duration
{
	my $duration_seconds = shift || 0;

	my $seconds = $duration_seconds;
	my $minutes = 0;
	$minutes = int($seconds / 60) if $seconds > 59;
	$seconds -= $minutes * 60 if $seconds;
	my $hours = 0;
	$hours = int($minutes / 60) if $minutes > 59;
	$minutes -= $hours * 60 if $hours;

	my $string = '';
	$string .= LDLNA::Utils::add_leading_char($hours,2,'0').':';
	$string .= LDLNA::Utils::add_leading_char($minutes,2,'0').':';
	$string .= LDLNA::Utils::add_leading_char($seconds,2,'0');

	return $string;
}

1;

#	if ($CONFIG{'SPECIFIC_VIEWS'})
#	{
#		$self->{DIRECTORIES}->{'A_A'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Audio sorted by Artist',
#			'id' => 'A_A',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'A_F'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Audio sorted by Folder',
#			'id' => 'A_F',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'A_G'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Audio sorted by Genre',
#			'id' => 'A_G',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'A_M'} = LDLNA::ContentDirectory->new({ # moods: WTF (dynamic)
#			'type' => 'meta',
#			'name' => 'Audio sorted by Mood',
#			'id' => 'A_M',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'A_T'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Audio sorted by Title (Alphabet)',
#			'id' => 'A_M',
#			'parent_id' => '',
#		});
#
#		$self->{DIRECTORIES}->{'I_F'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Images sorted by Folder',
#			'id' => 'I_F',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'I_T'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Images sorted by Date',
#			'id' => 'I_T',
#			'parent_id' => '',
#		});
#
#		$self->{DIRECTORIES}->{'V_D'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Videos sorted by Date',
#			'id' => 'V_D',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'V_F'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Videos sorted by Folder',
#			'id' => 'V_F',
#			'parent_id' => '',
#		});
#		$self->{DIRECTORIES}->{'V_T'} = LDLNA::ContentDirectory->new({
#			'type' => 'meta',
#			'name' => 'Videos sorted by Title (Alphabet)',
#			'id' => 'V_T',
#			'parent_id' => '',
#		});
#	}
