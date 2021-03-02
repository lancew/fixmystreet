use FixMyStreet::TestMech;
use FixMyStreet::Script::Reports;
use Test::MockModule;
use CGI::Simple;

my $mech = FixMyStreet::TestMech->new;

my $params = {
    send_method => 'Open311',
    send_comments => 1,
    api_key => 'KEY',
    endpoint => 'endpoint',
    jurisdiction => 'home',
    can_be_devolved => 1,
};
my $peterborough = $mech->create_body_ok(2566, 'Peterborough City Council', $params);
my $contact = $mech->create_contact_ok(email => 'FLY', body_id => $peterborough->id, category => 'General fly tipping');
my $user = $mech->create_user_ok('peterborough@example.org', name => 'Council User', from_body => $peterborough);
$peterborough->update( { comment_user_id => $user->id } );

subtest 'open311 request handling', sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        ALLOWED_COBRANDS => ['peterborough' ],
        MAPIT_URL => 'http://mapit.uk/',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Trees', email => 'TREES');
        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', { category => 'Trees', latitude => 52.5608, longitude => 0.2405, cobrand => 'peterborough' });
        $p->push_extra_fields({ name => 'emergency', value => 'no'});
        $p->push_extra_fields({ name => 'private_land', value => 'no'});
        $p->push_extra_fields({ name => 'PCC-light', value => 'whatever'});
        $p->push_extra_fields({ name => 'PCC-skanska-csc-ref', value => '1234'});
        $p->push_extra_fields({ name => 'tree_code', value => 'tree-42'});
        $p->update;

        my $test_data = FixMyStreet::Script::Reports::send();

        $p->discard_changes;
        ok $p->whensent, 'Report marked as sent';
        is $p->send_method_used, 'Open311', 'Report sent via Open311';
        is $p->external_id, 248, 'Report has correct external ID';
        is $p->get_extra_field_value('emergency'), 'no';

        my $req = $test_data->{test_req_used};
        my $c = CGI::Simple->new($req->content);
        is $c->param('attribute[description]'), "Title Test 1 for " . $peterborough->id . " Detail\r\n\r\nSkanska CSC ref: 1234", 'Ref added to description';
        is $c->param('attribute[emergency]'), undef, 'no emergency param sent';
        is $c->param('attribute[private_land]'), undef, 'no private_land param sent';
        is $c->param('attribute[PCC-light]'), undef, 'no pcc- param sent';
        is $c->param('attribute[tree_code]'), 'tree-42', 'tree_code param sent';
    };
};

subtest "extra update params are sent to open311" => sub {
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Trees', email => 'TREES');
        my $test_res = HTTP::Response->new();
        $test_res->code(200);
        $test_res->message('OK');
        $test_res->content('<?xml version="1.0" encoding="utf-8"?><service_request_updates><request_update><update_id>ezytreev-248</update_id></request_update></service_request_updates>');

        my $o = Open311->new(
            fixmystreet_body => $peterborough,
            test_mode => 1,
            test_get_returns => { 'servicerequestupdates.xml' => $test_res },
        );

        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', { external_id => 1, category => 'Trees', whensent => DateTime->now });

        my $c = FixMyStreet::DB->resultset('Comment')->create({
            problem => $p, user => $p->user, anonymous => 't', text => 'Update text',
            problem_state => 'fixed - council', state => 'confirmed', mark_fixed => 0,
            confirmed => DateTime->now(),
        });

        my $id = $o->post_service_request_update($c);
        is $id, "ezytreev-248", 'correct update ID returned';
        my $cgi = CGI::Simple->new($o->test_req_used->content);
        is $cgi->param('description'), '[Customer FMS update] Update text', 'FMS update prefix included';
        is $cgi->param('service_request_id_ext'), $p->id, 'Service request ID included';
        is $cgi->param('service_code'), $contact->email, 'Service code included';
    };
};

subtest "bartec report with no gecode handled correctly" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Bins', email => 'Bartec-Bins');
        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', { category => 'Bins', latitude => 52.5608, longitude => 0.2405, cobrand => 'peterborough' });

        my $test_data = FixMyStreet::Script::Reports::send();

        $p->discard_changes;
        ok $p->whensent, 'Report marked as sent';

        my $req = $test_data->{test_req_used};
        my $cgi = CGI::Simple->new($req->content);
        is $cgi->param('attribute[postcode]'), undef, 'postcode param not set';
        is $cgi->param('attribute[house_no]'), undef, 'house_no param not set';
        is $cgi->param('attribute[street]'), undef, 'street param not set';
    };
};

subtest "extra bartec params are sent to open311" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
            category => 'Bins',
            latitude => 52.5608,
            longitude => 0.2405,
            cobrand => 'peterborough',
            geocode => {
                resourceSets => [ {
                    resources => [ {
                        name => '12 A Street, XX1 1SZ',
                        address => {
                            addressLine => '12 A Street',
                            postalCode => 'XX1 1XZ'
                        }
                    } ]
                } ]
            },
            extra => {
                _fields => [
                    { name => 'site_code', value => '12345', },
                ],
            },
        } );

        my $test_data = FixMyStreet::Script::Reports::send();

        $p->discard_changes;
        ok $p->whensent, 'Report marked as sent';

        my $req = $test_data->{test_req_used};
        my $cgi = CGI::Simple->new($req->content);
        is $cgi->param('attribute[postcode]'), 'XX1 1XZ', 'postcode param sent';
        is $cgi->param('attribute[house_no]'), '12', 'house_no param sent';
        is $cgi->param('attribute[street]'), 'A Street', 'street param sent';
    };
};

my $mock = Test::MockModule->new('FixMyStreet::Cobrand::Peterborough');
$mock->mock('_fetch_features', sub {
    my ($self, $args, $x, $y) = @_;
    if ( $args->{type} && $args->{type} eq 'arcgis' ) {
        # council land
        if ( $x == 552617 && $args->{url} =~ m{2/query} ) {
            return [ { geometry => { type => 'Point' } } ];
        # leased out council land
        } elsif ( $x == 552651 && $args->{url} =~ m{3/query} ) {
            return [ { geometry => { type => 'Point' } } ];
        }

        return [];
    } else {
        # adopted roads
        if ( $x == 552721 && $args->{url} =~ m{tilma} ) {
            return [ { geometry => { type => 'Point' } } ];
        }
        return [];
    }
});

for my $test (
    {
        lat => 52.5708,
        desc => 'council land - send by open311',
        method => 'Open311',
    },
    {
        lat => 52.5608,
        desc => 'leased council land - send by email',
        method => 'Email',
    },
    {
        lat => 52.5508,
        desc => 'non council land - send by email',
        method => 'Email',
    },
    {
        lat => 52.5408,
        desc => 'adopted road - send by open311',
        method => 'Open311',
    },
) {
    subtest "check get_body_sender: " . $test->{desc} => sub {
        FixMyStreet::override_config {
            STAGING_FLAGS => { send_reports => 1 },
            MAPIT_URL => 'http://mapit.uk/',
            ALLOWED_COBRANDS => 'peterborough',
            COBRAND_FEATURES => { open311_email => { peterborough => { flytipping => 'flytipping@example.org' } } },
        }, sub {
            my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
                category => 'General fly tipping',
                latitude => $test->{lat},
                longitude => 0.2505,
                cobrand => 'peterborough',
            });

            my $cobrand = FixMyStreet::Cobrand::Peterborough->new;
            my $sender = $cobrand->get_body_sender($peterborough, $p);
            is $sender->{method}, $test->{method}, "correct body sender set";

            $p->update({ whensent => \"current_timestamp" });
        };
    };
}

subtest "flytipping on PCC land is sent by open311 and email" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
        COBRAND_FEATURES => { open311_email => { peterborough => { flytipping => 'flytipping@example.org' } } },
    }, sub {
        $mech->clear_emails_ok;

        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
            category => 'General fly tipping',
            latitude => 52.5708,
            longitude => 0.2505,
            cobrand => 'peterborough',
            geocode => {
                resourceSets => [ {
                    resources => [ {
                        name => '12 A Street, XX1 1SZ',
                        address => {
                            addressLine => '12 A Street',
                            postalCode => 'XX1 1XZ'
                        }
                    } ]
                } ]
            },
            extra => {
                _fields => [
                    { name => 'site_code', value => '12345', },
                ],
            },
        } );

        my $test_data = FixMyStreet::Script::Reports::send();
        $p->discard_changes;
        ok $p->whensent, 'Report marked as sent';
        ok !$p->get_extra_metadata('flytipping_email'), 'flytipping_email extra metadata not set';
        is $p->get_extra_metadata('sent_to')->[0], 'flytipping@example.org', 'sent_to extra metadata is set';
        is $p->state, 'confirmed', 'report state unchanged';
        is $p->comments->count, 0, 'no comment added';
        ok $test_data->{test_req_used}, 'open311 sent';
        my $cgi = CGI::Simple->new($test_data->{test_req_used}->content);
        is $cgi->param('service_code'), 'FLY', 'service code is correct';

        $mech->email_count_is(1);
        my $email = $mech->get_email;
        ok $email, "got an email";
        is $email->header('To'), '"Environmental Services" <flytipping@example.org>', 'email sent to correct address';
    };
};


subtest "flytipping on non PCC land is emailed" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
        COBRAND_FEATURES => { open311_email => { peterborough => { flytipping => 'flytipping@example.org' } } },
    }, sub {
        $mech->clear_emails_ok;

        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
            category => 'General fly tipping',
            latitude => 52.5608,
            longitude => 0.2405,
            cobrand => 'peterborough',
            geocode => {
                resourceSets => [ {
                    resources => [ {
                        name => '12 A Street, XX1 1SZ',
                        address => {
                            addressLine => '12 A Street',
                            postalCode => 'XX1 1XZ'
                        }
                    } ]
                } ]
            },
            extra => {
                _fields => [
                    { name => 'site_code', value => '12345', },
                ],
            },
        } );

        my $test_data = FixMyStreet::Script::Reports::send();

        $p->discard_changes;
        ok $p->whensent, 'Report marked as sent';
        is $p->get_extra_metadata('flytipping_email'), 'flytipping@example.org', 'flytipping_email extra metadata set';
        is $p->get_extra_metadata('sent_to')->[0], 'flytipping@example.org', 'sent_to extra metadata set';
        is $p->state, 'closed', 'report closed having sent email';
        is $p->comments->count, 1, 'comment added';
        like $p->comments->first->text, qr/As this is private land/, 'correct comment text';
        ok !$test_data->{test_req_used}, 'no open311 sent';

        $mech->email_count_is(1);
        my $email = $mech->get_email;
        ok $email, "got an email";
    };
};

subtest 'Dashboard CSV extra columns' => sub {
    my $staffuser = $mech->create_user_ok('counciluser@example.com', name => 'Council User',
        from_body => $peterborough, password => 'password');
    $mech->log_in_ok( $staffuser->email );
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        $mech->get_ok('/dashboard?export=1');
    };
    $mech->content_contains('"Reported As",USRN,"Nearest address"');
    $mech->content_contains('peterborough,,12345,"12 A Street, XX1 1SZ"');
};


done_testing;
