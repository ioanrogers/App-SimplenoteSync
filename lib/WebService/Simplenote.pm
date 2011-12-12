package WebService::Simplenote;

# ABSTRACT: access and sync with simplenoteapp.com

# TODO: cache authentication token between runs, use LWP cookie_jar for auth token
# TODO: How to handle simultaneous edits?
# TODO: Windows compatibility?? This has not been tested AT ALL yet
# TODO: Further testing on Linux - mainly file creation time
# TODO: Net::HTTP::Spore?
# TODO: use file extension to determine if a note is markdown or not?
# TODO: abstract synbc db use e.g. SQLite
# TODO: abstract note storage

our $VERSION = '0.001';

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use namespace::autoclean;

use LWP::UserAgent;
use Log::Any qw//;
use DateTime;
use MIME::Base64 qw//;
use JSON;
use Try::Tiny;
use Class::Load;

use WebService::Simplenote::Note;

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
    isa     => 'HashRef[WebService::Simplenote::Note]',
    default => sub { {} },
);

has store => (
    is       => 'rw',
    isa      => 'WebService::Simplenote::Storage',
    lazy => 1,
    builder => '_load_storage_plugin',
);

has storage_plugin => (
    is => 'ro',
    isa => 'Str',
    required => 1,
    lazy => 1,
    default => 'file',
);

has storage_opts => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
    lazy => 1,
    default => sub {{}},
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
            agent           => "WebService::Simplenote/$VERSION",
            default_headers => $headers,
        );
    },
);

# Connect to server and get a authentication token
sub _build_token {
    my $self = shift;

    my $content = MIME::Base64::encode_base64( sprintf 'email=%s&password=%s', $self->email, $self->password );

    $self->logger->debug('Network: get token');

    # the login uri uses api instead of api2 and must always be https
    my $response =
      $self->_ua->post( 'https://simple-note.appspot.com/api/login', Content => $content );

    if ( !$response->is_success ) {
        die "Error logging into Simplenote server: " . $response->status_line . "\n";
    }

    return $response->content;
}

sub _load_storage_plugin {
    my $self = shift;
    
    my $plugin = 'WebService::Simplenote::Storage::';
    $plugin .= ucfirst $self->storage_plugin;
    $self->logger->debug('Loading storage plugin: ' . $plugin);
    Class::Load::load_class($plugin);

    return $plugin->new($self->storage_opts);
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
        $notes->{ $i->{key} } = WebService::Simplenote::Note->new($i);
    }

    return $notes;
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
    $note = WebService::Simplenote::Note->new($new_data);

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

# Main Synchronization routine
sub sync_notes {
    my ($self) = @_;

    $self->logger->info('Starting sync run');
    # get list of existing notes from server with mod date and delete status
    my $remote_notes = $self->get_remote_index;

    # get previous sync info, if available
    $self->store->read_sync_db;

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
            my $note = WebService::Simplenote::Note->new(
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

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 LIMITATIONS

* If the simplenotesync.db file is lost, SimplenoteSync.pl is currently unable
  to realize that a text file and a note represent the same object --- instead
  you should move your local text files, do a fresh sync to download all notes
  locally, and manually replace any missing notes.

* Simplenote supports multiple notes with the same title, but two files cannot
  share the same filename. If you have two notes with the same title, only one
  will be downloaded. I suggest changing the title of the other note.

=head1 TROUBLESHOOTING

Optionally, you can enable or disable writing changes to either the local
directory or to the Simplenote web server. For example, if you want to attempt
to copy files to your computer without risking your remote data, you can
disable "$allow_server_updates". Or, you can disable "$allow_local_updates" to
protect your local data.

=head1 KNOWN ISSUES

* No merging when both local and remote file are changed between syncs - this
  might be enabled in the future

=head1 SEE ALSO

Designed for use with Simplenote:

<http://www.simplenoteapp.com/>

Based on SimplenoteSync:

<http://fletcherpenney.net/other_projects/simplenotesync/>
