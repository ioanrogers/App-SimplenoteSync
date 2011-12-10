#!/usr/bin/env perl -w

use Test::More tests => 3;

my $sync_dir = 't/notes';

use Webservice::SimpleNote::Note::File;

my $note = Webservice::SimpleNote::Note::File->new(
    createdate => 1323518226,
    modifydate => 1323518226,
    sync_dir   => $sync_dir,
);

ok( defined $note,                              'new() returns something' );
ok( $note->isa('Webservice::SimpleNote::Note'), '... the correct class' );

ok( my $json_str = $note->freeze, 'Serialise note to JSON' );
