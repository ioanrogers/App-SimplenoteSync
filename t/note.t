#!/usr/bin/env perl -w

use Test::More tests => 3;

require_ok('Webservice::SimpleNote::Note');

my $expected_json_str =
'{"__CLASS__":"Webservice::SimpleNote::Note","systemtags":[],"createdate":1323518226,"modifydate":1323518226,"deleted":"0","tags":[]}';

my $note = Webservice::SimpleNote::Note->new(
    createdate => 1323518226,
    modifydate => 1323518226,
);

ok( defined $note,                              'new() returns something' );
ok( $note->isa('Webservice::SimpleNote::Note'), '... the correct class' );

ok( my $json_str = $note->freeze, 'Serialiase note to JSON' );
