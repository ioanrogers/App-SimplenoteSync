#!/usr/bin/env perl -w

use Test::More tests => 4;

use WebService::Simplenote::Note;

my $expected_json_str =
'{"__CLASS__":"WebService::Simplenote::Note","systemtags":[],"createdate":1323518226,"modifydate":1323518226,"deleted":"0","tags":[]}';

my $note = WebService::Simplenote::Note->new(
    createdate => 1323518226,
    modifydate => 1323518226,
    content    => "# Some Content #\n This is a test",
);

ok( defined $note,                              'new() returns something' );
ok( $note->isa('WebService::Simplenote::Note'), '... the correct class' );

ok( my $json_str = $note->freeze, 'Serialise note to JSON' );

my $title = $note->_get_title_from_content;
cmp_ok($title, 'eq', 'Some Content', 'Title is correct');

