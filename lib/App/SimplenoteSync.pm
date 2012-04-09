package App::SimplenoteSync;

# ABSTRACT: Synchronise text notes with simplenoteapp.com

# TODO: Windows compatibility? This has not been tested AT ALL yet
# TODO: maybe hash file content to better determine if something has changed?

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use YAML::Any;
use Log::Any qw//;
use DateTime;
use Try::Tiny;
use File::ExtAttr ':all';
use App::SimplenoteSync::Note;
use WebService::Simplenote;
use namespace::autoclean;

has [ 'email', 'password' ] => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has notes => (
    is      => 'rw',
    isa     => 'HashRef[App::SimplenoteSync::Note]',
    default => sub { {} },
);

has stats => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub {
        {
            new_local     => 0,
            new_remote    => 0,
            update_local  => 0,
            update_remote => 0
        };
    },
);

has simplenote => (
    is      => 'rw',
    isa     => 'WebService::Simplenote',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return WebService::Simplenote->new(
            email             => $self->email,
            password          => $self->password,
            no_server_updates => $self->no_server_updates,
        );
    },
);

has [ 'no_server_updates', 'no_local_updates' ] => (
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

has notes_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
    builder  => '_build_notes_dir',
    trigger  => \&_check_notes_dir,
);

sub _build_notes_dir {
    my $self = shift;

    my $notes_dir = Path::Class::Dir->new( $ENV{HOME}, 'Notes' );

    if ( !-e $notes_dir ) {
        $notes_dir->mkpath
          or die "Failed to create notes dir: '$notes_dir': $!\n";
    }

    return $notes_dir;
}

sub _check_notes_dir {
    my $self = shift;
    if ( -d $self->notes_dir ) {
        return;
    }
    $self->notes_dir->mkpath
      or die "Sync directory [" . $self->notes_dir . "] does not exist\n";
}

sub _read_note_metadata {
    my ( $self, $note ) = @_;

    $self->logger->debugf( 'Looking for metadata for [%s]', $note->file->basename );

    my @attrs = listfattr( $note->file );
    if ( !@attrs ) {

        # no attrs probably means a new file
        $self->logger->debug( 'No metadata found' );
        return;
    }

    foreach my $attr ( @attrs ) {
        $self->logger->debugf( "attr: $attr" );
        next if $attr !~ /^simplenote\.(\w+)$/;
        my $key = $1;
        my $value = getfattr( $note->file, $attr );

        if ( $key eq 'systemtags' || $key eq 'tags' ) {
            my @tags = split ',', $value;
            $note->$key( \@tags );
        } else {
            $note->$key( $value );
        }
    }

    return 1;
}

sub _write_note_metadata {
    my ( $self, $note ) = @_;

    if ( $self->no_local_updates ) {
        return;
    }

    $self->logger->debugf( 'Writing note metadata for [%s]', $note->file->basename );

    # XXX only write if changed? Add a dirty attr?
    # XXX strip empty tags?
    my $metadata = {
        'simplenote.key'        => $note->key,
        'simplenote.tags'       => join( ',', @{ $note->tags } ),
        'simplenote.systemtags' => join( ',', @{ $note->systemtags } ),
    };

    foreach my $key ( keys $metadata ) {
        setfattr( $note->file, $key, $metadata->{$key} )
          or $self->logger->errorf( 'Error writing note metadata for [%s]', $note->file->basename );
    }

    return 1;
}

sub _get_note {
    my ( $self, $key ) = @_;

    my $original_note = $self->simplenote->get_note( $key );

    # 'cast' to our note type
    my $note = App::SimplenoteSync::Note->new( { %{$original_note}, notes_dir => $self->notes_dir } );

    if ( $self->no_local_updates ) {
        return;
    }

    my $fh = $note->file->open( 'w' );
    $fh->print( $note->content );
    $fh->close;

    # Set created and modified time
    # XXX: Not sure why this has to be done twice, but it seems to on Mac OS X
    utime $note->createdate->epoch, $note->modifydate->epoch, $note->file;

    #utime $create, $modify, $filename;
    $self->notes->{ $note->key } = $note;

    $self->_write_note_metadata( $note );

    $self->stats->{new_remote}++;

    return 1;
}

sub _delete_note {
    my ( $self, $note ) = @_;
    if ( $self->no_local_updates ) {
        return;
    }

    my $metadata_file = $self->metadata_dir->file( $note->key );
    $metadata_file->remove
      or $self->logger->warnf( 'Failed to remove metadata file: %s', $metadata_file->stringify );

    delete $self->notes->{ $note->key };

    $note->file->remove
      or $self->logger->errorf( 'Failed to remove note file: %s', $note->file->stringify );

    return 1;
}

sub _put_note {
    my ( $self, $note ) = @_;

    my $new_key = $self->simplenote->put_note( $note );
    if ( $new_key ) {
        $note->key( $new_key );
    }

    $self->{notes}->{ $note->key } = $note;
    return 1;
}

sub _merge_conflicts {

    # Both the local copy and server copy were changed since last sync
    # We'll merge the changes into a new master file, and flag any conflicts
    # TODO spawn some diff tool?
    my ( $self, $key ) = @_;

}

sub _merge_local_and_remote_lists {
    my ( $self, $remote_notes ) = @_;

    $self->logger->debug( "Comparing local and remote lists" );
    while ( my ( $key, $note ) = each $remote_notes ) {
        if ( exists $self->notes->{$key} ) {

            # which is newer?
            $self->logger->debug( "[$key] exists locally and remotely" );

            # TODO check if either side has trashed this note
            # TODO changed tags don't change modifydate
            # TODO versions and merging
            # No nanoseconds for utime
            $note->modifydate->set_nanosecond( 0 );
            $self->logger->debugf(
                'Comparing dates: remote [%s] // local [%s]',
                $note->modifydate->iso8601,
                $self->notes->{$key}->modifydate->iso8601
            );
            given ( DateTime->compare_ignore_floating( $note->modifydate, $self->notes->{$key}->modifydate ) ) {
                when ( 0 ) {
                    $self->logger->debug( "[$key] not modified" );
                }
                when ( 1 ) {
                    $self->logger->debug( "[$key] remote note is newer" );
                    $self->_get_note( $key );
                    $self->stats->{update_remote}++;
                }
                when ( -1 ) {
                    $self->logger->debug( "[$key] local note is newer" );
                    $self->_put_note( $self->notes->{$key} );
                    $self->stats->{update_local}++;
                }
            }
        } else {
            $self->logger->debug( "[$key] does not exist locally" );
            if ( !$note->deleted ) {
                $self->_get_note( $key );
            }
        }
    }

    return 1;
}

# TODO: check ctime
sub _update_dates {
    my ( $self, $note, $file ) = @_;

    my $mod_time = DateTime->from_epoch( epoch => $file->stat->mtime );

    given ( DateTime->compare( $mod_time, $note->modifydate ) ) {
        when ( 0 ) {

            # no change
            return;
        }
        when ( 1 ) {

            # file has changed
            $note->modifydate( $mod_time );
        }
        when ( -1 ) {
            die "File is older than sync db record?? Don't know what to do!\n";
        }
    }

    return 1;
}

sub _process_local_notes {
    my $self = shift;
    my $num_files = scalar $self->notes_dir->children( no_hidden => 1 );

    $self->logger->infof( 'Scanning [%d] files in [%s]', $num_files, $self->notes_dir->stringify );
    while ( my $f = $self->notes_dir->next ) {
        next unless -f $f;

        $self->logger->debug( "Checking local file [$f]" );

        # TODO: configure file extensions, or use mime types?
        next if $f !~ /\.(txt|mkdn)$/;

        my $content = $f->slurp;    # TODO: iomode + encoding

        my $note = App::SimplenoteSync::Note->new(
            createdate => $f->stat->ctime,
            modifydate => $f->stat->mtime,
            content    => $content,
            file       => $f,
            notes_dir  => $self->notes_dir,
        );

        if ( !$self->_read_note_metadata( $note ) ) {

            # don't have a key for it, assume is new
            # we could attempt to identify file remotely based on title
            # later on, but we don't
            $self->_put_note( $note );
            $self->_write_note_metadata( $note );
            $self->stats->{new_local}++;
        }

        # add note to list
        $self->notes->{ $note->key } = $note;
    }

    return 1;
}

sub sync_notes {
    my ( $self ) = @_;

    # then look for status of local notes
    $self->_process_local_notes;

    # get list of remote notes
    my $remote_notes = $self->simplenote->get_remote_index;
    if ( defined $remote_notes ) {

        # if there are any notes, they will need to be merged
        # as simplenote doesn't store title or filename info
        $self->_merge_local_and_remote_lists( $remote_notes );
    }

}

sub sync_report {
    my $self = shift;

    $self->logger->infof( 'New local files: ' . $self->stats->{new_local} );
    $self->logger->infof( 'Updated local files: ' . $self->stats->{update_local} );

    $self->logger->infof( 'New remote files: ' . $self->stats->{new_remote} );
    $self->logger->infof( 'Updated remote files: ' . $self->stats->{update_remote} );

}

__PACKAGE__->meta->make_immutable;

1;
