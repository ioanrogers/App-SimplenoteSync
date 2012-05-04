package App::SimplenoteSync;

# ABSTRACT: Synchronise text notes with simplenoteapp.com

# TODO: Windows compatibility? This has not been tested AT ALL yet
# TODO: maybe hash file content to better determine if something has changed?

use v5.10;
use open qw(:std :utf8);
use Moose;
use MooseX::Types::Path::Class;
use Method::Signatures;
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
            update_remote => 0,
            deleted_local => 0,
            trash         => 0,
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
    default  => 0,
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

method _build_notes_dir {
    
    my $notes_dir = Path::Class::Dir->new( $ENV{HOME}, 'Notes' );

    if ( !-e $notes_dir ) {
        $notes_dir->mkpath
          or die "Failed to create notes dir: '$notes_dir': $!\n";
    }

    return $notes_dir;
}

method _check_notes_dir {
    if ( -d $self->notes_dir ) {
        return;
    }
    $self->notes_dir->mkpath
      or die "Sync directory [" . $self->notes_dir . "] does not exist\n";
}

method _read_note_metadata ( App::SimplenoteSync::Note $note ) {
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

method _write_note_metadata ( App::SimplenoteSync::Note $note ) {
    if ( $self->no_local_updates ) {
        return;
    }

    $self->logger->debugf( 'Writing note metadata for [%s]', $note->file->basename );

    # XXX only write if changed? Add a dirty attr?
    # should always be a key
    my $metadata = {
        'simplenote.key' => $note->key,
    };

    if ($note->has_systags) {
        $metadata->{'simplenote.systemtags'} = $note->join_systags(',');
    }
    
    if ($note->has_tags) {
        $metadata->{'simplenote.tags'} = $note->join_tags(',');
    }
    
    foreach my $key ( keys %$metadata ) {
        setfattr( $note->file, $key, $metadata->{$key} )
          or $self->logger->errorf( 'Error writing note metadata for [%s]', $note->file->basename );
    }

    return 1;
}

method _get_note (Str $key) {
    my $original_note = $self->simplenote->get_note( $key );

    # 'cast' to our note type
    my $note = App::SimplenoteSync::Note->new( { %{$original_note}, notes_dir => $self->notes_dir } );

    if ( $self->no_local_updates ) {
        return;
    }
    my $fh = $note->file->open( 'w' );

    # data from simplenote should always be utf8
    $fh->binmode(':utf8');
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

method _delete_note (App::SimplenoteSync::Note $note) {
    if ( $self->no_local_updates ) {
        $self->logger->warn( 'no_local_updates is set, not deleting note' );
        return;
    }
    
    my $removed = $note->file->remove;
    if ($removed) {
        $self->logger->debugf( 'Deleted [%s]', $note->file->stringify );
        $self->stats->{deleted_local}++;
    } else {
        $self->logger->errorf( "Failed to delete [%s]: $!", $note->file->stringify );
    }
    
    delete $self->notes->{ $note->key };

    return 1;
}

method _put_note (App::SimplenoteSync::Note $note) {
    
    if (!defined $note->content) {
       my $content;
       try {
           $content = $note->file->slurp;
       } catch {
           $self->logger->error( "Failed to read file: $_" );
           return;
       };
       
       $note->content($content);
    }
    
    $self->logger->infof( 'Uploading file: [%s]', $note->file->stringify );
    my $new_key = $self->simplenote->put_note( $note );
    if ( $new_key ) {
        $note->key( $new_key );
    }

    $self->{notes}->{ $note->key } = $note;
    return 1;
}

method merge_conflicts {

    # Both the local copy and server copy were changed since last sync
    # We'll merge the changes into a new master file, and flag any conflicts
    # TODO spawn some diff tool?

}

method _merge_local_and_remote_lists(HashRef $remote_notes ) {;
    $self->logger->debug( "Comparing local and remote lists" );
    
    # XXX what about notes which were deleted on the server, and are to be restored
    # from local files? i.e key set locally, not existent remotely? How to tell
    # if the file SHOULD be trashed? User option, perhaps --restore
    
    while ( my ( $key, $remote_note ) = each %$remote_notes ) {
        if ( exists $self->notes->{$key} ) {
            my $local_note = $self->notes->{$key};
            
            $self->logger->debug( "[$key] exists locally and remotely" );

            if ($remote_note->deleted) {
                $self->logger->warnf( "[$key] has been trashed remotely. Deleting local copy in [%s]",
                    $local_note->file->stringify
                );
                $self->_delete_note($local_note);        
            }
            
            # TODO changed tags don't change modifydate
            # TODO versions and merging
            # which is newer?
            $remote_note->modifydate->set_nanosecond( 0 ); # utime doesn't use nanoseconds
            $self->logger->debugf(
                'Comparing dates: remote [%s] // local [%s]',
                $remote_note->modifydate->iso8601,
                $local_note->modifydate->iso8601
            );
            given ( DateTime->compare_ignore_floating( $remote_note->modifydate, $local_note->modifydate ) ) {
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
                    $self->_put_note( $local_note );
                    $self->stats->{update_local}++;
                }
            }
        } else {
            $self->logger->debug( "[$key] does not exist locally" );
            if ( !$remote_note->deleted ) {
                $self->_get_note( $key );
            } else {
                $self->stats->{trash}++;
            }
        }
    }
    
    # try the other way to catch deleted notes
    while ( my ( $key, $local_note ) = each %{$self->notes} ) {
         if ( !exists $remote_notes->{$key} ) {
            # if a local file has metadata, specifically simplenote.key
            # but doesn't exist remotely it must have been deleted there
            $self->logger->warnf( "[$key] does not exist remotely. Deleting local copy in [%s]",
                $local_note->file->stringify
            );
            $self->_delete_note($local_note);        
         } 
    }
    
    return 1;
}

# TODO: check ctime
method _update_dates (App::SimplenoteSync::Note $note, Path::Class::File $file ) {
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

method _process_local_notes {
    my $num_files = scalar $self->notes_dir->children( no_hidden => 1 );

    $self->logger->infof( 'Scanning [%d] files in [%s]', $num_files, $self->notes_dir->stringify );
    while ( my $f = $self->notes_dir->next ) {
        next unless -f $f;

        $self->logger->debug( "Checking local file [$f]" );

        # TODO: configure file extensions, or use mime types?
        next if $f !~ /\.(txt|mkdn)$/;
        
        my $note = App::SimplenoteSync::Note->new(
            createdate => $f->stat->ctime,
            modifydate => $f->stat->mtime,
            file       => $f,
            notes_dir  => $self->notes_dir,
        );

        if ( !$self->_read_note_metadata( $note ) ) {

            # don't have a key for it, assume is new
            $self->_put_note( $note );
            $self->_write_note_metadata( $note );
            $self->stats->{new_local}++;
        }

        # add note to list
        $self->notes->{ $note->key } = $note;
    }

    return 1;
}

method sync_notes {
    #  look for status of local notes
    $self->_process_local_notes;

    # get list of remote notes
    my $remote_notes = $self->simplenote->get_remote_index;
    if ( defined $remote_notes ) {

        # if there are any notes, they will need to be merged
        # as simplenote doesn't store title or filename info
        $self->_merge_local_and_remote_lists( $remote_notes );
    }

}

method sync_report {
    $self->logger->infof( 'New local files: ' . $self->stats->{new_local} );
    $self->logger->infof( 'Updated local files: ' . $self->stats->{update_local} );

    $self->logger->infof( 'New remote files: ' . $self->stats->{new_remote} );
    $self->logger->infof( 'Updated remote files: ' . $self->stats->{update_remote} );
    
    $self->logger->infof( 'Deleted local files: ' . $self->stats->{deleted_local} );
    $self->logger->infof( 'Ignored remote trash: ' . $self->stats->{trash} );

}

__PACKAGE__->meta->make_immutable;

1;
