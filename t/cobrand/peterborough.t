use FixMyStreet::TestMech;
use FixMyStreet::Script::Reports;
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

my $problem;
subtest "bartec report with no gecode handled correctly" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Bins', email => 'Bartec-Bins');
        ($problem) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', { category => 'Bins', latitude => 52.5608, longitude => 0.2405, cobrand => 'peterborough', areas => ',2566,' });

        my $test_data = FixMyStreet::Script::Reports::send();

        $problem->discard_changes;
        ok $problem->whensent, 'Report marked as sent';

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

subtest 'Dashboard CSV extra columns' => sub {
    my $staffuser = $mech->create_user_ok('counciluser@example.com', name => 'Council User',
        from_body => $peterborough, password => 'password');
    $staffuser->user_body_permissions->create({ body => $peterborough, permission_type => 'report_edit' });
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

subtest 'Resending between backends' => sub {
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Pothole', email => 'Bartec-POT');
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Fallen tree', email => 'Ezytreev-Fallen');
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Flying tree', email => 'Ezytreev-Flying');
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Graffiti', email => 'graffiti@example.org', send_method => 'Email');

    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        # $problem is in Bins category from creation, which is Bartec
        my $whensent = $problem->whensent;
        $mech->get_ok('/admin/report_edit/' . $problem->id);
        foreach (
            { category => 'Pothole', resent => 0 },
            { category => 'Fallen tree', resent => 1 },
            { category => 'Flying tree', resent => 0 },
            { category => 'Graffiti', resent => 1, method => 'Email' },
            { category => 'Trees', resent => 1 }, # Not due to forced, but due to send method change
            { category => 'Bins', resent => 1 },
        ) {
            $mech->submit_form_ok({ with_fields => { category => $_->{category} } }, "Switch to $_->{category}");
            $problem->discard_changes;
            if ($_->{resent}) {
                is $problem->whensent, undef, "Marked for resending";
                $problem->update({ whensent => $whensent, send_method_used => $_->{method} || 'Open311' }); # reset as sent
            } else {
                isnt $problem->whensent, undef, "Not marked for resending";
            }
        }
    };
};

done_testing;
