package Webservice::SimpleNote;

# ABSTRACT: access and sync with simplenoteapp.com

# TODO: cache authentication token between runs
# TODO: How to handle simultaneous edits?
# TODO: need to compare information between local and remote files when same title in both (e.g. simplenotesync.db lost, or collision)
# TODO: Windows compatibility?? This has not been tested AT ALL yet
# TODO: Further testing on Linux - mainly file creation time
# TODO: Net::HTTP::Spore?
# TODO: use file extension to determine if a note is markdown or not?
# TODO: use LWP cookie_jar for auth token
# TODO: abstract synbc db use e.g. SQLite
# TODO: abstract note storage

our $VERSION = '0.001';

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use Webservice::SimpleNote::Note;
use LWP::UserAgent;
use Log::Any qw//;
use DateTime;
use DateTime::Format::HTTP;
use MIME::Base64;
use JSON;
use Try::Tiny;
use Encode qw/decode_utf8/;
use YAML::Any qw/Dump LoadFile DumpFile/;

has [ 'email', 'password' ] => (
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

has notes => (
    is      => 'rw',
    isa     => 'HashRef[Webservice::SimpleNote::Note]',
    default => sub { {} },
);

has sync_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
);

has sync_db => (
    is       => 'ro',
    isa      => 'Path::Class::File',
    required => 1,
    coerce   => 1,
);

has [ 'allow_server_updates', 'allow_local_updates' ] => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 1,
);

has logger => (
    is       => 'ro',
    isa      => 'Object',
    lazy     => 1,
    required => 1,
    default  => sub { return Log::Any->get_logger },
);

has _uri => (
    is       => 'ro',
    isa      => 'Str',
    default  => 'https://simple-note.appspot.com/api2',
    required => 1,
);

has _ua => (
    is      => 'rw',
    isa     => 'LWP::UserAgent',
    default => sub {
        my $headers = HTTP::Headers->new( Content_Type => 'application/json', );
        return LWP::UserAgent->new(
            agent           => "Webservice::SimpleNote/$VERSION",
            default_headers => $headers,
        );
    },
);

sub _build_sync_dir {
    my $self = shift;
    if ( !-d $self->sync_dir ) {

        # Target directory doesn't exist
        die "Sync directory [" . $self->sync_dir . "] does not exist\n";
    }
}

# my $store_base_text = 0;		# Trial mode to allow conflict resolution

# Initialize database of newly synchronized files
my %newNotes;

# Initialize database of files that were deleted this round
my %deletedFromDatabase;

# Connect to server and get a authentication token
sub _build_token {
    my $self = shift;

    my $content = encode_base64( sprintf 'email=%s&password=%s', $self->email, $self->password );

    $self->logger->debug('Network: get token');

    # the login uri uses api instead of api2 and must always be https
    my $response =
      $self->_ua->post( 'https://simple-note.appspot.com/api/login', Content => $content );

    if ( !$response->is_success ) {
        die "Error logging into Simplenote server:\n" . $response->status_line . "\n";
    }

    return $response->content;
}

# Get list of notes from simplenote server
# TODO since, mark, length options
sub get_remote_index {
    my $self  = shift;
    my $notes = {};

    $self->logger->debug('Network: get note index');
    my $req_uri  = sprintf '%s/index?auth=%s&email=%s', $self->_uri, $self->token, $self->email;
    my $response = $self->_ua->get($req_uri);
    my $index    = decode_json( $response->content );

    $self->logger->debugf( 'Network: Index returned [%s] notes', $index->{count} );

    # iterate through notes in index and load into hash
    foreach my $i ( @{ $index->{data} } ) {
        $notes->{ $i->{key} } = Webservice::SimpleNote::Note->new($i);
    }

    say Dump($notes);
    return $notes;
}

# Convert note's title into file
sub title_to_filename {
    my ( $self, $title ) = @_;

    # Strip prohibited characters
    $title =~ s/[:\\\/]/ /g;
    my $file = $self->sync_dir->file( "$title.txt" );
    $self->logger->debug("Title [$title] => File [$file]");
    return $file;
}

# Convert filename into title and unescape special characters
sub filename_to_title {
    my ( $self, $file ) = @_;
    my $title = $file->basename;
    $title =~ s/\.$self->file_extension$//;
    $self->logger->debug("File [$file] => Title [$title]");
    return $title;
}

# Given a local file, upload it as a note at simplenote web server
sub upload_file_to_note {
    my ( $self, $file, $key ) = @_;    # Supply key if we are updating existing note

    my $title = $self->filename_to_title($file);    # The title for new note

    my $content = "\n";                             # The content for new note
    $content .= $file->slurp;

    # Check to make sure text file is encoded as UTF-8
    if ( eval { decode_utf8( $content, Encode::FB_CROAK ); 1 } ) {

        # $content is valid utf8
        $self->logger->debug("[$file] is utf8 encoded");
    } else {

        # TODO not on a mac??
        # $content is not valid utf8 - assume it's macroman and convert
        $self->logger->debug("[$file] is not a UTF-8 file. Converting");
        $content = decode( 'MacRoman', $content );
        utf8::encode($content);
    }

    #time_thingy
    my ( $modified, $created ) = 'blah';

    if ( !$self->allow_server_updates ) {
        $self->logger->warn('Sending notes to the server is disabled');
        return;
    }

    if ( defined($key) ) {

        # We are updating an old note

        $self->logger->debug("Network: update existing note [$title]");
        my $modifyString = $modified ? "&modify=$modified" : "";
        my $req_uri = sprintf '%s/note?key=%s&auth=%s&email=%s%s', $self->_uri, $key,
          $self->token, $self->email, $modifyString;
        my $response =
          $self->_ua->post( $req_uri, Content => encode_base64( $title . "\n" . $content ) );

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
        }
    }

    return $key;
}

# TODO: only for file storage
sub _get_title_from_content {
    my ( $self, $content ) = @_;

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

    return $title;
}

# Save local copy of note from Simplenote server
sub get_note {
    my ( $self, $note ) = @_;

    $self->logger->debugf( 'Network: retrieve existing note [%s]', $note->key );

    # TODO are there any other encoding options?
    my $req_uri = sprintf '%s/data/%s?auth=%s&email=%s', $self->_uri, $note->key,
      $self->token, $self->email;
    my $response = $self->_ua->get($req_uri);
    
    if ( !$response->is_success ) {
        $self->logger->errorf( '[%s] could not be retrieved: %s',
            $note->key, $response->status_line );
        return;
    }
    my $new_data = decode_json($response->content);
    # XXX: anything to merge?
    $note = Webservice::SimpleNote::Note->new($new_data);
    
    $note->title($self->_get_title_from_content( $note->content ));
    $note->file($self->title_to_filename($note->title));

    if ( !$self->allow_local_updates ) {
        return;
    }
    my $fh = $note->file->open('w');
    $fh->print($note->content);
    $fh->close;

    # Set created and modified time
    # XXX: Not sure why this has to be done twice, but it seems to on Mac OS X
    utime $note->createdate->epoch, $note->modifydate->epoch, $note->file;
    #utime $create, $modify, $filename;

    return;
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

sub time_thingy {
    my ( $self, $file ) = @_;

    # my @d = gmtime( ( $file->stat) )[9] );
    # $file{$filepath}{modify} = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1,
    # $d[3], $d[2], $d[1], $d[0];

    # #         if ( $^O =~ /darwin/i ) {

    # #             # The following works on Mac OS X - need a "birth time", not ctime
    # # created time
    # @d = gmtime( readpipe("stat -f \"%B\" \"$filepath\"") );
    # } else {

    # #             # TODO: Need a better way to do this on non Mac systems
    # # get file's modification time
    # @d = gmtime( ( stat("$filepath") )[9] );
    # }

# #         $file{$filepath}{create} = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1,
# $d[3], $d[2], $d[1], $d[0];
}

# Iterate through sync database and assess current state of those files
sub get_local_index {
    my $self = shift;

    # get previous sync info, if available
    my $local_notes = $self->_read_sync_database;

    return $local_notes;

    foreach my $note ( keys %{$local_notes} ) {
        if ( -f $note->file ) {
            $self->logger->debugf( '[%s]->[%s] exists', $note, $note->file->stringify );
            my $file_mtime = DateTime->from_epoch( epoch => $note->file->stat->mtime );
            if ( DateTime->compare( $note->modify, $file_mtime ) == 0 ) {

                # file appears unchanged
                $self->logger->debug("[$note] local copy unchanged");

                # #                 if ( defined( $note->{$key}{modify} ) ) {

                # #                     # Remote copy also exists
                # $self->logger->debug("[$key] remote copy exists");

                # #                     if ( $note->{$key}->modify eq $last_mod_date ) {

                # #                         # note on server also appears unchanged

                # #                         # Nothing more to do
                # } else {

                # #                         # note on server has changed, but local file hasn't
                # $self->logger->debug("[$key] remote file is changed");
                # if ( $note->{$key}->deleted ) {

                # #                             # Remote note was flagged for deletion
                # $self->logger->info("Deleting [$filename] as it was deleted on server");
                # if ( $self->allow_local_updates ) {
                # File::Path::rmtree("$self->sync_dir/$filename");
                # delete( $file{"$self->sync_dir/$filename"} );
                # }
                # } else {

                # #                             # Remote note not flagged for deletion
                # # update local file and overwrite if necessary
                # my $newFile = $self->download_note_to_file( $key, $self->sync_dir, 1 );

            # #                             if ( ( $newFile ne $filename ) && ( $newFile ne "" ) ) {
            # $self->logger->info(
            # "Deleting [$filename] as it was renamed to [$newFile]");

               # #                                 # The file was renamed on server; delete old copy
               # if ( $self->allow_local_updates ) {
               # File::Path::rmtree("$self->sync_dir/$filename");
               # delete( $file{"$self->sync_dir/$filename"} );
               # }
               # }
               # }
               # }

                # #                     # Remove this file from other queues
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                # } else {

                # #                     # remote file is gone, delete local
                # $self->logger->debug("Delete [$filename]");
                # File::Path::rmtree("$self->sync_dir/$filename")
                # if ( $self->allow_local_updates );
                # $deletedFromDatabase{$key} = 1;
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                # }
                # } else {

                # #                 # local file appears changed
                # $self->logger->debug("[$filename] has changed");

                # #                 if ( $note->{$key}{modify} eq $last_mod_date ) {

                # #                     # but note on server is old
                # $self->logger->debug("[$filename] server copy is unchanged");

                # #                     # update note on server
                # $self->upload_file_to_note( "$self->sync_dir/$filename", $key );

                # #                     # Remove this file from other queues
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                # } else {

               # #                     # note on server has also changed
               # $self->logger->warn(
               # "[$filename] was modified locally and on server - please check file for conflicts."
               # );

                # #                     # Use the stored copy from last sync to enable a three way
                # #	merge, then use this as the official copy and allow
                # #	user to manually edit any conflicts

                # #                     #$self->merge_conflicts($key);

                # #                     # Remove this file from other queues
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                # }
                # }
                # } else {

                # #             # no file exists - it must have been deleted locally
                # if ( $note->{$key}->modify eq $last_mod_date ) {

                # #                 # note on server also appears unchanged

                # #                 # so we delete this file
                # $self->logger->debug("Killing [$filename]");
                # $self->delete_note_online($key);

                # #                 # Remove this file from other queues
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                # $deletedFromDatabase{$key} = 1;

                # #             } else {

                # #                 # note on server has also changed

                # #                 if ( $note->{$key}->deleted ) {

                # #                     # note on server was deleted also
                # $self->logger->debug("Deleting [$filename]");

                # #                     # Don't do anything locally
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                # } else {
                # $self->logger->warn("[$filename] deleted locally but modified on server");

                # #                     # So, download from the server to resync, and
                # #	user must then re-delete if desired
                # $self->download_note_to_file( $key, $self->sync_dir, 0 );

                # #                     # Remove this file from other queues
                # delete( $note->{$key} );
                # delete( $file{"$self->sync_dir/$filename"} );
                #    }
            }
        }
    }
}

# Main Synchronization routine
sub sync_notes {
    my ($self) = @_;

    # get list of existing notes from server with mod date and delete status
    my $remote_notes = $self->get_remote_index;

    # get previous sync info, if available
    my $local_notes = $self->get_local_index;

    # merge notes
    while ( my ( $key, $note ) = each $local_notes ) {
        $self->notes->{$key} = $note;
    }

    while ( my ( $key, $note ) = each $remote_notes ) {
        if ( exists $self->notes->{$key} ) {

            # which is newer?
            $self->logger->debug("[$key] exists locally and remotely");
            given ( DateTime->compare( $note->modifydate, $self->notes->{$key}->modifydate ) ) {
                when (0) {
                    $self->logger->debug("[$key] not modified");
                }
                when (1) {
                    $self->logger->debug("[$key] remote note is newer");
                }
                when (-1) {
                    $self->logger->debug("[$key] local note is newer");
                }
            }
        } else {
            $self->logger->debug("[$key] does not exist localy");
            if ( !$note->deleted ) {
                $self->get_note($note);
            }
        }
    }

    # TODO abstract this out
    # Finally, we need to look at new files locally and upload to server
    $self->logger->debugf( 'Looking for new files in [%s]', $self->sync_dir->stringify );
    while ( my $f = $self->sync_dir->next ) {
        next unless -f $f;
        $self->logger->debug("Checking $f");
        my $is_known = 0;
        foreach my $note ( @{ $self->notes } ) {
            if ( $note->file eq $f ) {
                $is_known = 1;
                last;
            }
        }
        if ($is_known) {
            $self->logger->debug("New local file [$f]");
            my $note = Webservice::SimpleNote::Note->new(
                createdate => $f->stat->ctime,
                modifydate => $f->stat->mtime,
                content    => $f->slurp,
            );
            $self->upload_file_to_note($note);
        }
    }

}

sub _read_sync_database {
    my $self = shift;
    my $notes;

    try {
        $notes = LoadFile( $self->sync_db );
    };

    if ( !defined $notes ) {
        $self->logger->debug('No existing sync db');
        return {};
    }

    return $notes;
}

sub _write_sync_database {
    my $self = shift;

    if ( !$self->allow_local_updates ) {
        return;
    }

    $self->logger->debug('Writing sync db');

    DumpFile( $self->sync_db, $self->notes );
}

no Moose;
__PACKAGE__->meta->make_immutable;

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
