#!/usr/bin/env perl -w

use Test::More;

if (!defined $ENV{SIMPLENOTE_USER} ) {
    plan skip_all => 'Set SIMPLENOTE_USER and SIMPLENOTE_PASS for remote tests';
}
else {
    plan tests => 2;
}

require 'WebService::Simplenote';

my $sn = WebService::Simplenote->new;
ok( defined $note,                              'new() returns something' );
ok( $note->isa('WebService::Simplenote::Note'), '... the correct class' );
