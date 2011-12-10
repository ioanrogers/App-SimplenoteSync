package Webservice::SimpleNote::Storage::DB_File;

# ABSTRACT: Stores the notes in a db file

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use YAML::Any qw/Dump LoadFile DumpFile/;
use namespace::autoclean;

extends 'Webservice::SimpleNote::Storage';

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

sub _read_sync_db {
    my $self = shift;
    my $notes;

    return 1;
}

sub _write_sync_db {
    my $self = shift;

    if ( !$self->allow_local_updates ) {
        return;
    }

}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
