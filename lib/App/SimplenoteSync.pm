package WebService::SimplenoteSync;

# ABSTRACT: access and sync with simplenoteapp.com

# TODO: How to handle simultaneous edits?
# TODO: Windows compatibility?? This has not been tested AT ALL yet
# TODO: Further testing on Linux - mainly file creation time
# TODO: use file extension to determine if a note is markdown or not?

our $VERSION = '0.001';

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use namespace::autoclean;

use Log::Any qw//;
use DateTime;
use Try::Tiny;

use WebService::Simplenote::Note;

has [ 'email', 'password' ] => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has notes => (
    is      => 'rw',
    isa     => 'HashRef[WebService::Simplenote::Note]',
    default => sub { {} },
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

sub delete_note {
    my ( $self, $note ) = @_;
    if ( !$self->allow_local_updates ) {
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
    
    $self->simplenote->sync_notes;
    
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
