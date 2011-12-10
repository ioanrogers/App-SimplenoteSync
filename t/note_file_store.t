#!/usr/bin/env perl -w

use Test::More tests => 4;

my $sync_dir = 't/notes';

require_ok('Webservice::SimpleNote::Note::File');

my $note = Webservice::SimpleNote::Note::File->new(
    createdate => 1323518226,
    modifydate => 1323518226,
);

ok( defined $note,                              'new() returns something' );
ok( $note->isa('Webservice::SimpleNote::Note'), '... the correct class' );

ok( my $json_str = $note->freeze, 'Serialise note to JSON' );
