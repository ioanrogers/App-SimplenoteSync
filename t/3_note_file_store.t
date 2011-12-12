#!/usr/bin/env perl -w

use Test::More tests => 3;

my $sync_dir = 't/notes';

use WebService::Simplenote::Note::File;

my $note = WebService::Simplenote::Note::File->new(
    createdate => 1323518226,
    modifydate => 1323518226,
    sync_dir   => $sync_dir,
);

ok( defined $note,                              'new() returns something' );
ok( $note->isa('WebService::Simplenote::Note'), '... the correct class' );

ok( my $json_str = $note->freeze, 'Serialise note to JSON' );
