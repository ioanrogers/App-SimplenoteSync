#!/usr/bin/env perl -w

use Test::More;

if (!defined $ENV{SIMPLENOTE_USER} ) {
    plan skip_all => 'Set SIMPLENOTE_USER and SIMPLENOTE_PASS for remote tests';
}
else {
    plan tests => 2;
}

require 'Webservice::SimpleNote';

my $sn = Webservice::SimpleNote->new;
ok( defined $note,                              'new() returns something' );
ok( $note->isa('Webservice::SimpleNote::Note'), '... the correct class' );
