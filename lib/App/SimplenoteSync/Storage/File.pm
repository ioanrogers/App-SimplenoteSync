package WebService::Simplenote::Storage::File;

# ABSTRACT: Handles storage of the notes and metadata

# TODO: need to compare information between local and remote files when same title in both (e.g. simplenotesync.db lost, or collision)

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use Try::Tiny;
use YAML::Any qw/Dump LoadFile DumpFile/;
use namespace::autoclean;

extends 'WebService::Simplenote::Storage';

has sync_db => (
    is       => 'rw',
    isa      => 'Path::Class::File',
    coerce   => 1,
);

has sync_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
    metaclass => 'DoNotSerialize',
    trigger  => \&_check_sync_dir,
);

sub _check_sync_dir {
    my $self = shift;
    if ( -d $self->sync_dir ) {
        return;
    }
    $self->sync_dir->mkpath
        or die "Sync directory [" . $self->sync_dir . "] does not exist\n";
}

sub read_sync_db {
    my $self = shift;
    my $notes;

    try {
        $notes = LoadFile( $self->sync_db );
    };

    if ( !defined $notes ) {
        $self->logger->debug('No existing sync db');
        return;
    }

    return $notes;
}

sub write_sync_db {
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
