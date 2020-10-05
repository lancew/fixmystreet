use CGI::Simple;
use Test::MockModule;
use Test::MockTime qw(:all);
use FixMyStreet::TestMech;
use FixMyStreet::Script::Reports;
use Catalyst::Test 'FixMyStreet::App';

use_ok 'FixMyStreet::Cobrand::CentralBedfordshire';

my $mech = FixMyStreet::TestMech->new;

my $body = $mech->create_body_ok(21070, 'Central Bedfordshire Council', {
    send_method => 'Open311', api_key => 'key', 'endpoint' => 'e', 'jurisdiction' => 'j' });
$mech->create_contact_ok(body_id => $body->id, category => 'Bridges', email => "BRIDGES");

FixMyStreet::override_config {
    ALLOWED_COBRANDS => [ 'centralbedfordshire' ],
    MAPIT_URL => 'http://mapit.uk/',
    STAGING_FLAGS => { send_reports => 1, skip_checks => 0 },
    COBRAND_FEATURES => {
        area_code_mapping => { centralbedfordshire => {
            59795 => 'Area1',
            60917 => 'Area2',
            60814 => 'Area3',
        } },
    },
}, sub {

    subtest 'cobrand displays council name' => sub {
        ok $mech->host("centralbedfordshire.fixmystreet.com"), "change host to centralbedfordshire";
        $mech->get_ok('/');
        $mech->content_contains('Central Bedfordshire');
    };

    subtest 'cobrand displays council name' => sub {
        $mech->get_ok('/reports/Central+Bedfordshire');
        $mech->content_contains('Central Bedfordshire');
    };

    my ($report) = $mech->create_problems_for_body(1, $body->id, 'Test Report', {
        category => 'Bridges', cobrand => 'centralbedfordshire',
        latitude => 52.030695, longitude => -0.357033, areas => ',117960,11804,135257,148868,21070,37488,44682,59795,65718,83582,',
    });

    subtest 'Correct area_code parameter for Open311' => sub {
        my $test_data = FixMyStreet::Script::Reports::send();
        my $req = $test_data->{test_req_used};
        my $c = CGI::Simple->new($req->content);
        is $c->param('service_code'), 'BRIDGES';
        is $c->param('attribute[area_code]'), 'Area1';

        $mech->email_count_is(0);
    };
};

done_testing();