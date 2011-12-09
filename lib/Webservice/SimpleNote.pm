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

    return $notes;
}

# Convert note's title into file
sub title_to_filename {
    my ( $self, $title ) = @_;

    # Strip prohibited characters
    $title =~ s/\W/_/g;
    # TODO trim 
    my $file = $self->sync_dir->file("$title.txt");
    $self->logger->debug("Title [$title] => File [$file]");
    return $file;
}

# Convert filename into title and unescape special characters
sub filename_to_title {
    my ( $self, $file ) = @_;
    my $title = $file->basename;
    $title =~ s/\.txt$//;
    $self->logger->debug("File [$file] => Title [$title]");
    return $title;
}

# Given a local file, upload it as a note at simplenote web server
sub put_note {
    my ( $self, $note ) = @_;

    if ( !$self->allow_server_updates ) {
        $self->logger->warn('Sending notes to the server is disabled');
        return;
    }
    
    my $json = JSON->new;
    $json->allow_blessed;
    $json->convert_blessed;
    
    my $req_uri = sprintf '%s/data', $self->_uri;

    if ( defined $note->key ) {
        $self->logger->infof( '[%s] Updating existing note', $note->key );
        $req_uri .= '/' . $note->key,;
    } else {
        $self->logger->debug('Uploading new note');
    }

    $req_uri .= sprintf '?auth=%s&email=%s', $self->token, $self->email;
    $self->logger->debug("Network: POST to [$req_uri]");
    my $content = $json->utf8->encode($note);
    
    my $response = $self->_ua->post( $req_uri, Content => $content );

    if ( !$response->is_success ) {
        $self->logger->error( 'Failed uploading note: ' . $response->status_line );
    }

    my $note_data = decode_json( $response->content );

    if ( !defined $note->key ) {
        $note->key( $note_data->{key} );
    }
    
    $self->{notes}->{$note->key} = $note;
    
    return 1;
}

# TODO: only for file storage
sub _get_title_from_content {
    my ( $self, $note ) = @_;
    
    my $content = $note->content;
    
    # TODO look for first line which contains some \w
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

    $self->logger->infof( 'Retrieving note [%s]', $note->key );

    # TODO are there any other encoding options?
    my $req_uri = sprintf '%s/data/%s?auth=%s&email=%s', $self->_uri, $note->key,
      $self->token, $self->email;
    my $response = $self->_ua->get($req_uri);

    if ( !$response->is_success ) {
        $self->logger->errorf( '[%s] could not be retrieved: %s',
            $note->key, $response->status_line );
        return;
    }
    my $new_data = decode_json( $response->content );

    # XXX: anything to merge?
    $note = Webservice::SimpleNote::Note->new($new_data);

    $note->title( $self->_get_title_from_content( $note ) );
    $note->file( $self->title_to_filename( $note->title ) );

    if ( !$self->allow_local_updates ) {
        return;
    }
    my $fh = $note->file->open('w');
    $fh->print( $note->content );
    $fh->close;

    # Set created and modified time
    # XXX: Not sure why this has to be done twice, but it seems to on Mac OS X
    utime $note->createdate->epoch, $note->modifydate->epoch, $note->file;

    #utime $create, $modify, $filename;
    $self->notes->{$note->key} = $note;

    return 1;
}

# If title is too long, it won't be a valid filename
sub trim_title {
    my ( $self, $title ) = @_;

    $title =~ s/^(.{1,240}).*?$/$1/;
    $title =~ s/(.*)\s.*?$/$1/;        # Try to trim at a word boundary

    return $title;
}

# Delete specified note from Simplenote server
sub delete_note {
    my ( $self, $note ) = @_;
    if ( !$self->allow_server_updates ) {
        return;
    }
    # XXX worth checking if note is flagged as deleted?
    $self->logger->infof('[%s] Deleting from trash', $note->key);

    my $req_uri = sprintf '%s/data?key=%s&auth=%s&email=%s', $self->_uri, $note->key, $self->token,
          $self->email;
    
    my $response = $self->_ua->delete($req_uri);
    
    if (!$response->is_success) {
        $self->logger->errorf('[%s] Failed to delete note from trash: %s', $note->key, $response->status_line);
        return;
    }
    
    delete $self->notes->{$note->key};
    return 1;
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

# Main Synchronization routine
sub sync_notes {
    my ($self) = @_;

    $self->logger->info('Starting sync run');
    # get list of existing notes from server with mod date and delete status
    my $remote_notes = $self->get_remote_index;

    # get previous sync info, if available
    $self->_read_sync_database;

    while ( my ( $key, $note ) = each $remote_notes ) {
        if ( exists $self->notes->{$key} ) {

            # which is newer?
            $self->logger->debug("[$key] exists locally and remotely");
            # TODO check if either side has trashed this note
            given ( DateTime->compare( $note->modifydate, $self->notes->{$key}->modifydate ) ) {
                when (0) {
                    $self->logger->debug("[$key] not modified");
                }
                when (1) {
                    $self->logger->debug("[$key] remote note is newer");
                    $self->get_note($note);
                }
                when (-1) {
                    $self->logger->debug("[$key] local note is newer");
                    $self->put_note($note);
                }
            }
        } else {
            $self->logger->debug("[$key] does not exist locally");
            if ( !$note->deleted ) { # TODO this is app-level decision
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
        foreach my $note ( values %{ $self->notes } ) {
            $self->logger->debugf('Comparing [%s] to [%s]', $note->file->stringify, $f->stringify); 
            if ( $note->file eq $f ) {
                $is_known = 1;
                last;
            }
        }
        if (!$is_known) {
            $self->logger->info("New local file [$f]");
            my $content = $f->slurp; # TODO: iomode + encoding
            my $note = Webservice::SimpleNote::Note->new(
                createdate => $f->stat->ctime,
                modifydate => $f->stat->mtime,
                content    => $content,
                systemtags => ['markdown'],
                file       => $f,
            );

            $self->put_note($note);
        }
    }
    
    $self->_write_sync_database;
    $self->logger->info('Finished sync run');
}

sub _read_sync_database {
    my $self = shift;
    my $notes;

    try {
        $notes = LoadFile( $self->sync_db );
    };

    if ( !defined $notes ) {
        $self->logger->debug('No existing sync db');
        return;
    }

    $self->notes($notes);
    return 1;
}

sub _write_sync_database {
    my $self = shift;

    if ( !$self->allow_local_updates ) {
        return;
    }

    $self->logger->debug('Writing sync db');
    # XXX only write if changed? Add a dirty attr?
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
