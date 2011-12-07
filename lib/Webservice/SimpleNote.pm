package Webservice::SimpleNote;

# ABSTRACT: access and sync with simplenoteapp.com

# TODO: cache authentication token between runs
# TODO: How to handle simultaneous edits?
# TODO: need to compare information between local and remote files when same title in both (e.g. simplenotesync.db lost, or collision)
# TODO: Windows compatibility?? This has not been tested AT ALL yet
# TODO: Further testing on Linux - mainly file creation time
# TODO: Net::HTTP::Spore?

use v5.10;
use Moose;
use MooseX::Types::Path::Class;

use LWP::UserAgent;
use Log::Any qw//;
use File::Basename;
use File::Path;
use Cwd 'abs_path';
use MIME::Base64;

use Time::Local;
use File::Copy;
use Encode qw/decode_utf8/;
use Data::Dumper;

has [ 'email', 'password', 'token' ] => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has token => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    lazy     => 1,
    builder  => '_build_token',
);

has file_extension => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => 'txt',
);

has [ 'rc_dir', 'sync_dir' ] => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
    #builder => '_
);

has allow_server_updates => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => '1',
);

has logger => (
    is       => 'ro',
    isa      => 'Any',
    lazy     => 1,
    required => 1,
    default  => sub { return Log::Any->get_logger },
);

has _uri => (
    is       => 'ro',
    isa      => 'Str',
    default  => 'https://simple-note.appspot.com/api',
    required => 1,
);

has _ua => (
    is      => 'rw',
    isa     => 'LWP::UserAgent',
    default => sub { return LWP::UserAgent->new; },
);

sub _build_sync_dir {
    my $self = shift;
    if ( !-d $self->sync_dir ) {

        # Target directory doesn't exist
        die "Sync directory [" . $self->sync_dir . "] does not exist\n";
    }
}

# my $store_base_text = 0;		# Trial mode to allow conflict resolution

# Initialize Database of last sync information into global array
#my $hash_ref = init_sync_database($sync_directory);
#my %syncNotes = %$hash_ref;
my %syncNotes;

# Initialize database of newly synchronized files
my %newNotes;

# Initialize database of files that were deleted this round
my %deletedFromDatabase;

# Connect to server and get a authentication token
sub _build_token {
    my $self = shift;

    my $content = encode_base64( sprintf 'email=%s&password=%s', $self->email, $self->password );

    $self->logger->debug('Network: get token');
    my $response = $self->_ua->post( $self->_uri . "/login", Content => $content );

    if ( $response->content =~ /Invalid argument/ ) {
        die "Problem connecting to web server.\nHave you installed Crypt:SSLeay as instructed?\n";
    }

    if ( !$response->is_success ) {
        die "Error logging into Simplenote server:\n" . Dumper($response) . "\n";
    }

    return $response->content;
}

# Get list of notes from simplenote server
sub get_note_index {
    my $self = shift;
    my %note = ();

    $self->logger->debug('Network: get note index');
    my $req_uri  = sprintf '%s/index?auth=%s&email=%s', $self->_uri, $self->token, $self->email;
    my $response = $self->_ua->get($req_uri);
    my $index    = $response->content;

    $index =~ s{
		\{(.*?)\}
	}{
		# iterate through notes in index and load into hash
		my $notedata = $1;
		
		$notedata =~ /"key":\s*"(.*?)"/;
		my $key = $1;
		
		while ($notedata =~ /"(.*?)":\s*"?(.*?)"?(,|\Z)/g) {
			# load note data into hash
			if ($1 ne "key") {
				$note{$key}{$1} = $2;
			}
		}
		
		# Trim fractions of seconds from modification time
		$note{$key}{modify} =~ s/\..*$//;
	}egx;

    return \%note;
}

# Convert note's title into valid filename
sub title_to_filename {
    my ( $self, $title ) = @_;

    # Strip prohibited characters
    $title =~ s/[:\\\/]/ /g;

    $title .= '.' . $self->file_extension;

    return $title;
}

# Convert filename into title and unescape special characters
sub filename_to_title {
    my ( $self, $filename ) = @_;

    $filename = basename($filename);
    $filename =~ s/\.$self->file_extension$//;

    return $filename;
}

# Given a local file, upload it as a note at simplenote web server
sub upload_file_to_note {
    my ( $self, $filepath, $key ) = @_;    # Supply key if we are updating existing note

    my $title = $self->filename_to_title($filepath);    # The title for new note

    my $content = "\n";                                 # The content for new note
    open( my $in, '<', $filepath );
    local $/;
    $content .= <$in>;
    close($in);

    # Check to make sure text file is encoded as UTF-8
    if ( eval { decode_utf8( $content, Encode::FB_CROAK ); 1 } ) {

        # $content is valid utf8
        $self->logger->debug("$filepath is utf8 encoded");
    } else {

        # TODO not on a mac??
        # $content is not valid utf8 - assume it's macroman and convert
        $self->logger->debug("$filepath is not a UTF-8 file. Converting");
        $content = decode( 'MacRoman', $content );
        utf8::encode($content);
    }

    my @d = gmtime( ( stat("$filepath") )[9] );    # get file's modification time
    my $modified = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1, $d[3], $d[2],
      $d[1], $d[0];

    if ( $^O =~ /darwin/i ) {

        # The following works on Mac OS X - need a "birth time", not ctime
        @d = gmtime( readpipe("stat -f \"%B\" \"$filepath\"") );    # created time
    } else {

        # TODO: Need a better way to do this on non Mac systems
        @d = gmtime( ( stat("$filepath") )[9] );                    # get file's modification time
    }

    my $created = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1, $d[3], $d[2],
      $d[1], $d[0];

    if ( defined($key) ) {

        # We are updating an old note
        if ( $self->allow_server_updates ) {
            $self->logger->debug("Network: update existing note [$title]");
            my $modifyString = $modified ? "&modify=$modified" : "";
            my $req_uri = sprintf '%s/note?key=%s&auth=%s&email=%s%s', $self->_uri, $key,
              $self->token, $self->email, $modifyString;
            my $response =
              $self->_ua->post( $req_uri, Content => encode_base64( $title . "\n" . $content ) );
        } else {
            $self->logger->warn('Sending notes to the server is disabled');
        }

    } else {

        # We are creating a new note

        my $modifyString = $modified ? "&modify=$modified" : "";
        my $createString = $created  ? "&create=$created"  : "";

        if ( $self->allow_server_updates ) {
            $self->logger->debug("Network: create new note [$title]");
            my $req_uri = sprintf '%s/note?auth=%s&email=%s%s%s', $self->_uri, $self->token,
              $self->email, $modifyString, $createString;
            my $response =
              $self->_ua->post( $req_uri, Content => encode_base64( $title . "\n" . $content ) );

            # Return the key of the newly created note
            if ( $self->allow_server_updates ) {
                $key = $response->content;
            } else {
                $key = 0;
            }
        } else {
            $self->logger->warn('Sending notes to the server is disabled');
        }
    }

    # Add this note to the sync'ed list for writing to database
    $newNotes{$key}{modify} = $modified;
    $newNotes{$key}{create} = $created;
    $newNotes{$key}{title}  = $title;
    $newNotes{$key}{file}   = titleToFilename($title);

    # TODO storage paths
    #if (($store_base_text) && ($allow_local_updates)) {
    # # Put a copy of note in storage
    # my $copy = dirname($filepath) . "/SimplenoteSync Storage/" . basename($filepath);
    # copy($filepath,$copy);
    # }

    return $key;
}

# Save local copy of note from Simplenote server
sub download_note_to_file {
    my ( $self, $key, $directory, $overwrite ) = @_;

    #my $storage_directory = "$directory/SimplenoteSync Storage";

    # retrieve note

    $self->logger->debug("Network: retrieve existing note [$key]");

    # TODO are there any other encoding options?
    my $req_uri = sprintf '%s/note?key=%s&auth=%s&email=%s&encode=base64', $self->_uri, $key,
      $self->token, $self->email;
    my $response = $self->_ua->get($req_uri);
    my $content  = decode_base64( $response->content );

    if ( $content eq "" ) {

        # No such note exists any longer
        $self->logger->warn("$key no longer exists on server");
        $deletedFromDatabase{$key} = 1;
        return;
    }

    # Parse into title and content (if present)
    $content =~ s/^(.*?)(\n{1,2}|\Z)//s;    # First line is title
    my $title   = $1;
    my $divider = $2;

    # If first line is particularly long, it will get trimmed, so
    # leave it in body, and make a short version for the title
    if ( length($title) > 240 ) {

        # Restore first line to content and create new title
        $content = $title . $divider . $content;
        $title   = $self->trim_title($title);
    }

    my $filename = $self->title_to_filename($title);

    # If note is marked for deletion on the server, don't download
    if ( $response->header('note-deleted') eq "True" ) {
        if ( ( $overwrite == 1 ) && ( $self->allow_local_updates ) ) {

            # If we're in overwrite mode, then delete local copy
            File::Path::rmtree("$directory/$filename");
            $deletedFromDatabase{$key} = 1;

            # if ($store_base_text) {
            # # Delete storage copy
            # File::Path::rmtree("$storage_directory/$filename");
            # }
        } else {
            $self->logger->debug("Note [$key] was flagged for deletion on server - not downloaded");

            # Optionally, could add "&dead=1" to force Simplenote to remove
            #	this note from the database. Could cause problems on iPhone
            #	Just for future reference....
            $deletedFromDatabase{$key} = 1;
        }
        return "";
    }

    # Get time of note creation (trim fractions of seconds)
    my $create = my $createString = $response->header('note-createdate');
    $create =~ /(\d\d\d\d)-(\d\d)-(\d\d)\s*(\d\d):(\d\d):(\d\d)/;
    $create = timegm( $6, $5, $4, $3, $2 - 1, $1 );
    $createString =~ s/\..*$//;

    # Get time of note modification (trim fractions of seconds)
    my $modify = my $modifyString = $response->header('note-modifydate');
    $modify =~ /(\d\d\d\d)-(\d\d)-(\d\d)\s*(\d\d):(\d\d):(\d\d)/;
    $modify = timegm( $6, $5, $4, $3, $2 - 1, $1 );
    $modifyString =~ s/\..*$//;

    # Create new file

    if (   ( -f "$directory/$filename" )
        && ( $overwrite == 0 ) )
    {

        # A file already exists with that name, and we're not intentionally
        #	replacing with a new copy.
        $self->logger->warn("$filename already exists. Will not download.");

        return "";
    } else {
        if ( $self->allow_local_updates ) {
            open( my $fh, '>', "$directory/$filename" );
            print $fh $content;
            close $fh;

            # if ($store_base_text) {
            # # Put a copy in storage
            # open (FILE, ">$storage_directory/$filename");
            # print FILE $content;
            # close FILE;
            # }

            # Set created and modified time
            # Not sure why this has to be done twice, but it seems to on Mac OS X
            utime $create, $create, "$directory/$filename";
            utime $create, $modify, "$directory/$filename";

            $newNotes{$key}{modify} = $modifyString;
            $newNotes{$key}{create} = $createString;
            $newNotes{$key}{file}   = $filename;
            $newNotes{$key}{title}  = $title;

            # Add this note to the sync'ed list for writing to database
            return $filename;
        }
    }

    return "";
}

# If title is too long, it won't be a valid filename
sub trim_title {
    my ( $self, $title ) = @_;

    $title =~ s/^(.{1,240}).*?$/$1/;
    $title =~ s/(.*)\s.*?$/$1/;        # Try to trim at a word boundary

    return $title;
}

# Delete specified note from Simplenote server
sub delete_note_online {
    my ( $self, $key ) = @_;

    if ( $self->allow_server_updates ) {
        $self->logger->debug("Network: delete note [$key].");
        my $req_uri = sprintf '%s/delete?key=%s&auth=%s&email=%s', $self->_uri, $key, $self->token,
          $self->email;
        my $response = $self->_ua->get($req_uri);
        return $response->content;
    } else {
        return "";
    }
}

sub merge_conflicts {

    # Both the local copy and server copy were changed since last sync
    # We'll merge the changes into a new master file, and flag any conflicts
    # TODO spawn some diff tool?
    my ( $self, $key ) = @_;

}

# Main Synchronization routine
sub sync_notes_to_folder {
    my ($self) = @_;

    # my $storage_directory = "$directory/SimplenoteSync Storage";
    # if ((! -e $storage_directory) && $store_base_text) {
    # # This directory saves a copy of the text at each successful sync
    # #	to allow three way merging
    # mkdir $storage_directory;
    # }

    # get list of existing notes from server with mod date and delete status
    my $note_ref = $self->get_note_index;
    my %note     = %$note_ref;

    # get list of existing local text files with mod/creation date
    my %file;

    my $glob_directory = $self->sync_dir;
    $glob_directory =~ s/ /\\ /g;

    foreach my $filepath ( glob("$glob_directory/*.$self->file_extension") ) {
        $filepath = abs_path($filepath);
        my @d = gmtime( ( stat("$filepath") )[9] );
        $file{$filepath}{modify} = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1,
          $d[3], $d[2], $d[1], $d[0];

        if ( $^O =~ /darwin/i ) {

            # The following works on Mac OS X - need a "birth time", not ctime
            # created time
            @d = gmtime( readpipe("stat -f \"%B\" \"$filepath\"") );
        } else {

            # TODO: Need a better way to do this on non Mac systems
            # get file's modification time
            @d = gmtime( ( stat("$filepath") )[9] );
        }

        $file{$filepath}{create} = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1,
          $d[3], $d[2], $d[1], $d[0];
    }

    # Iterate through sync database and assess current state of those files

    foreach my $key ( keys %syncNotes ) {

        # Cycle through each prior note from last sync
        my $last_mod_date = $syncNotes{$key}{modify};
        my $filename      = $syncNotes{$key}{file};

        if ( defined( $file{"$self->sync_dir/$filename"} ) ) {

            # the current item appears to exist as a local file
            $self->logger->debug("[$filename] exists");
            if ( $file{"$self->sync_dir/$filename"}{modify} eq $last_mod_date ) {

                # file appears unchanged
                $self->logger->debug("[$key] local copy unchanged");

                if ( defined( $note{$key}{modify} ) ) {

                    # Remote copy also exists
                    $self->logger->debug("[$key] remote copy exists");

                    if ( $note{$key}{modify} eq $last_mod_date ) {

                        # note on server also appears unchanged

                        # Nothing more to do
                    } else {

                        # note on server has changed, but local file hasn't
                        $self->logger->debug("[$key] remote file is changed");
                        if ( $note{$key}{deleted} eq "true" ) {

                            # Remote note was flagged for deletion
                            $self->logger->info("Deleting [$filename] as it was deleted on server");
                            if ( $self->allow_local_updates ) {
                                File::Path::rmtree("$self->sync_dir/$filename");
                                delete( $file{"$self->sync_dir/$filename"} );
                            }
                        } else {

                            # Remote note not flagged for deletion
                            # update local file and overwrite if necessary
                            my $newFile = $self->download_note_to_file( $key, $self->sync_dir, 1 );

                            if ( ( $newFile ne $filename ) && ( $newFile ne "" ) ) {
                                $self->logger->info(
                                    "Deleting [$filename] as it was renamed to [$newFile]");

                                # The file was renamed on server; delete old copy
                                if ( $self->allow_local_updates ) {
                                    File::Path::rmtree("$self->sync_dir/$filename");
                                    delete( $file{"$self->sync_dir/$filename"} );
                                }
                            }
                        }
                    }

                    # Remove this file from other queues
                    delete( $note{$key} );
                    delete( $file{"$self->sync_dir/$filename"} );
                } else {

                    # remote file is gone, delete local
                    $self->logger->debug("Delete [$filename]");
                    File::Path::rmtree("$self->sync_dir/$filename")
                      if ( $self->allow_local_updates );
                    $deletedFromDatabase{$key} = 1;
                    delete( $note{$key} );
                    delete( $file{"$self->sync_dir/$filename"} );
                }
            } else {

                # local file appears changed
                $self->logger->debug("[$filename] has changed");

                if ( $note{$key}{modify} eq $last_mod_date ) {

                    # but note on server is old
                    $self->logger->debug("[$filename] server copy is unchanged");

                    # update note on server
                    $self->upload_file_to_note( "$self->sync_dir/$filename", $key );

                    # Remove this file from other queues
                    delete( $note{$key} );
                    delete( $file{"$self->sync_dir/$filename"} );
                } else {

                    # note on server has also changed
                    $self->logger->warn(
"[$filename] was modified locally and on server - please check file for conflicts."
                    );

                    # Use the stored copy from last sync to enable a three way
                    #	merge, then use this as the official copy and allow
                    #	user to manually edit any conflicts

                    #$self->merge_conflicts($key);

                    # Remove this file from other queues
                    delete( $note{$key} );
                    delete( $file{"$self->sync_dir/$filename"} );
                }
            }
        } else {

            # no file exists - it must have been deleted locally

            if ( $note{$key}{modify} eq $last_mod_date ) {

                # note on server also appears unchanged

                # so we delete this file
                $self->logger->debug("Killing [$filename]");
                $self->delete_note_online($key);

                # Remove this file from other queues
                delete( $note{$key} );
                delete( $file{"$self->sync_dir/$filename"} );
                $deletedFromDatabase{$key} = 1;

            } else {

                # note on server has also changed

                if ( $note{$key}{deleted} eq "true" ) {

                    # note on server was deleted also
                    $self->logger->debug("Deleting [$filename]");

                    # Don't do anything locally
                    delete( $note{$key} );
                    delete( $file{"$self->sync_dir/$filename"} );
                } else {
                    $self->logger->warn("[$filename] deleted locally but modified on server");

                    # So, download from the server to resync, and
                    #	user must then re-delete if desired
                    $self->download_note_to_file( $key, $self->sync_dir, 0 );

                    # Remove this file from other queues
                    delete( $note{$key} );
                    delete( $file{"$self->sync_dir/$filename"} );
                }
            }
        }
    }

    # Now, we need to look at new notes on server and download
    foreach my $key ( sort keys %note ) {

        # Download, but don't overwrite existing file if present
        if ( $note{$key}{deleted} ne "true" ) {
            $self->download_note_to_file( $key, $self->sync_dir, 0 );
        }
    }

    # Finally, we need to look at new files locally and upload to server
    foreach my $new_file ( sort keys %file ) {
        $self->logger->debug("New local file [$new_file]");
        $self->upload_file_to_note($new_file);
    }
}

sub init_sync_database {

    # from <http://docstore.mik.ua/orelly/perl/cookbook/ch11_11.htm>

    my ( $self, $directory ) = @_;
    my %synchronizedNotes = ();

    if ( open( DB, "<$directory/simplenotesync.db" ) ) {

        $/ = "";    # paragraph read mode
        while (<DB>) {
            my @array = ();

            my @fields = split /^([^:]+):\s*/m;
            shift @fields;    # for leading null field
            push( @array, { map /(.*)/, @fields } );

            for my $record (@array) {
                for my $key ( sort keys %$record ) {
                    $synchronizedNotes{ $record->{key} }{$key} = $record->{$key};
                }
            }
        }

        close DB;
    }

    return \%synchronizedNotes;
}

sub write_sync_database {

    # from <http://docstore.mik.ua/orelly/perl/cookbook/ch11_11.htm>
    my $self = shift;
    return 0 if ( !$self->allow_local_updates );
    my ($directory) = @_;

    open( DB, ">$directory/simplenotesync.db" );

    foreach my $record ( sort keys %newNotes ) {
        for my $key ( sort keys %{ $newNotes{$record} } ) {
            $syncNotes{$record}{$key} = ${ $newNotes{$record} }{$key};
        }
    }

    foreach my $key ( sort keys %deletedFromDatabase ) {
        delete( $syncNotes{$key} );
    }

    foreach my $record ( sort keys %syncNotes ) {
        print DB "key: $record\n";
        for my $key ( sort keys %{ $syncNotes{$record} } ) {
            print DB "$key: ${$syncNotes{$record}}{$key}\n";
        }
        print DB "\n";
    }

    close DB;
}

1;

=head1 DESCRIPTION

After specifying a folder to store local text files, and the email address and
password associated with your Simplenote account, SimplenoteSync will attempt
to synchronize the information in both places.

Sync information is stored in "simplenotesync.db". If this file is lost,
SimplenoteSync will have to attempt to look for "collisions" between local
files and existing notes. When performing the first synchronization, it's best
to start with an empty local folder (or an empty collection of notes on
Simplenote), and then start adding files (or notes) afterwards.

=head1 WARNING

Please note that this software is still in development stages --- I STRONGLY
urge you to backup all of your data before running to ensure nothing is lost.
If you run SimplenoteSync on an empty local folder without a
"simplenotesync.db" file, the net result will be to copy the remote notes to
the local folder, effectively performing a backup.

=head1 FEATURES

* Bidirectional synchronization between the Simplenote web site and a local
  directory of text files on your computer

* Ability to upload notes to your iPhone without typing them by hand

* Ability to backup the notes on your iPhone

* Perform synchronizations automatically by using cron

* Should handle unicode characters in title and content (works for me in some
  basic tests, but let me know if you have trouble)

* The ability to manipulate your notes (via the local text files) using other
  applications (e.g. [Notational Velocity](http://notational.net/) if you use
  "Plain Text Files" for storage, shell scripts, AppleScript, 
  [TaskPaper](http://www.hogbaysoftware.com/products/taskpaper), etc.) -
  you're limited only by your imagination

* COMING SOON --- The ability to attempt to merge changes if a note is changed
  locally and on the server simultaneously

=head1 LIMITATIONS

* Certain characters are prohibited in filenames (:,\,/) - if present in the
  title, they are stripped out.

* If the simplenotesync.db file is lost, SimplenoteSync.pl is currently unable
  to realize that a text file and a note represent the same object --- instead
  you should move your local text files, do a fresh sync to download all notes
  locally, and manually replace any missing notes.

* Simplenote supports multiple notes with the same title, but two files cannot
  share the same filename. If you have two notes with the same title, only one
  will be downloaded. I suggest changing the title of the other note.


=head1 FAQ

* When I try to use SimplenoteSync, I get the following error:

=over

=over

Network: get token

Error logging into Simplenote server:

HTTP::Response=HASH(0x1009b0110)->content

=back

The only time I have seen this error is when the username or password is
entered into the configuration file incorrectly. Watch out for spaces at the
end of lines.

=back


* Why can I download notes from Simplenote, but local notes aren't being
  uploaded?

=over

Do the text files end in ".txt"? For documents to be recognized as text files
to be uploaded, they have to have that file extension. *Unless* you have
specified an alternate file extension to use in ".simplenotesyncrc".

Text files can't be located in subdirectories - this script does not (by
design) recurse folders looking for files (since they shouldn't be anywhere
but the specified directory).

=back

* When my note is downloaded from Simplenote and then changed locally, I end
  up with two copies of the first line (one shorter than the other) - what
  gives?

=over

If the first line of a note is too long to become the filename, it is trimmed
to an appropriate length. To prevent losing data, the full line is preserved
in the body. Since Simplenote doesn't have a concept of titles, the title
becomes the first line (which is trimmed), and the original first line is now
the third line (counting the blank line in between). Your only alternatives
are to shorten the first line, split it in two, or to create a short title

=back

* If I rename a note, what happens?

=over

If you rename a note on Simplenote by changing the first line, a new text file
will be created and the old one will be deleted, preserving the original
creation date. If you rename a text file locally, the old note on Simplenote
will be deleted and a new one will be created, again preserving the original
creation date. In the second instance, there is not actually any recognition
of a "rename" going on - simply the recognition that an old note was deleted
and a new one exists.

=back

=head1 TROUBLESHOOTING

If SimplenoteSync isn't working, I've tried to add more (and better) error
messages. Common problems so far include:

* Not installing Crypt::SSLeay

* Errors in the "simplenotesyncrc" file

Optionally, you can enable or disable writing changes to either the local
directory or to the Simplenote web server. For example, if you want to attempt
to copy files to your computer without risking your remote data, you can
disable "$allow_server_updates". Or, you can disable "$allow_local_updates" to
protect your local data.

Additionally, there is a script "Debug.pl" that will generate a text file with
some useful information to email to me if you continue to have trouble.

=head1 KNOWN ISSUES

* No merging when both local and remote file are changed between syncs - this
  might be enabled in the future

* the code is still somewhat ugly

* it's probably not very efficient and might really bog down with large
  numbers of notes

* renaming notes or text files causes it to be treated as a new note -
  probably not all bad, but not sure what else to do. For now, you'll have to
  manually delete the old copy


=head1 SEE ALSO

Designed for use with Simplenote for iPhone:

<http://www.simplenoteapp.com/>

Based on SimplenoteSync:

<http://fletcherpenney.net/other_projects/simplenotesync/>
