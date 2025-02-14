package FixMyStreet::App;
use Moose;
use namespace::autoclean;

use Catalyst::Runtime 5.80;
use FixMyStreet;
use FixMyStreet::App::Response;
use FixMyStreet::Cobrand;
use Memcached;
use FixMyStreet::Map;
use FixMyStreet::Email;
use FixMyStreet::Email::Sender;
use FixMyStreet::PhotoStorage;
use Utils;

use FixMyStreet::Auth::GoogleAuth;
use Path::Tiny 'path';
use Try::Tiny;
use Text::CSV;
use URI;
use URI::QueryParam;

use Catalyst (
    'Static::Simple',
    'Session',
    'Session::Store::DBIC',
    'Session::State::Cookie',    # FIXME - we're using our own override atm
    'Authentication',
    'SmartURI',
    'FixMyStreet::Session::RotateSession',
    'FixMyStreet::Session::StoreSessions',
);

extends 'Catalyst';

our $VERSION = '0.01';

my $store = {         # Catalyst::Authentication::Store::DBIx::Class
    class => 'DBIx::Class',
    user_model => 'DB::User',
    store_user_class => 'Catalyst::Authentication::Store::FixMyStreetUser',
};

__PACKAGE__->config(

    # Use REQUEST_URI, not PATH_INFO, to infer path. This fixes an issue
    # with slashes in category names in admin (as PATH_INFO can't tell
    # the difference between / and %2F)
    use_request_uri_for_path => 1,

    # get the config from the core object
    %{ FixMyStreet->config() },

    name => 'FixMyStreet::App',

    # Disable deprecated behavior needed by old applications
    disable_component_resolution_regex_fallback => 1,

    # Some generic stuff
    default_view => 'Web',

    # Serve anything in web dir that is not a .cgi script
    'Plugin::Static::Simple' => {
        include_path      => [ FixMyStreet->path_to("web") . "" ],
        ignore_extensions => ['cgi'],
    },

    'Plugin::Session' => {    # Catalyst::Plugin::Session::Store::DBIC
        dbic_class     => 'DB::Session',
        expires        => 3600 * 24 * 7 * 4, # 4 weeks
        cookie_secure  => 2,
    },

    'Plugin::Authentication' => {
        default_realm => 'default',
        default       => {
            credential => {
                class => 'MultiFactor',
                factors => [
                  # Catalyst::Authentication::Credential::Password
                  {
                      class => 'Password',
                      password_field => 'password',
                      password_type => 'self_check',
                  },
                  {
                      class => '2FA',
                  },
                ],
            },
            store => $store,
        },
        no_password => {       # use post confirm etc
            credential => {    # Catalyst::Authentication::Credential::Password
                class         => 'Password',
                password_type => 'none',
            },
            store => $store,
        },
        access_token => {
            use_session => 0,
            credential => {
                class => 'AccessToken',
            },
            store => $store,
        },
    },
);

__PACKAGE__->response_class('FixMyStreet::App::Response');

# Start the application
__PACKAGE__->setup();

# If your site is secure but running behind a proxy, you might need to set the
# SECURE_PROXY_SSL_HEADER configuration variable so this can be spotted.
after 'prepare_headers' => sub {
    my $self = shift;
    my $base_url = $self->config->{BASE_URL};
    my $ssl_header = $self->config->{SECURE_PROXY_SSL_HEADER};
    my $host = $self->req->headers->header('Host');
    $self->req->secure(1) if $ssl_header && ref $ssl_header eq 'ARRAY'
        && @$ssl_header == 2 && $self->req->header($ssl_header->[0]) eq $ssl_header->[1];
};

# disable debug logging unless in debug mode
__PACKAGE__->log->disable('debug')    #
  unless __PACKAGE__->debug;

# Set up photo storage
unless ( FixMyStreet::PhotoStorage::backend->init() ) {
    warn "\x1b[31mCan't set up photo storage backend\x1b[0m\n";
}

=head1 NAME

FixMyStreet::App - Catalyst based application

=head1 SYNOPSIS

    script/fixmystreet_app_server.pl

=head1 DESCRIPTION

FixMyStreet.com codebase

=head1 METHODS

=head2 cobrand

    $cobrand = $c->cobrand();

Returns the cobrand object. If not already determined this request finds it and
caches it to the stash.

=cut

sub cobrand {
    my $c = shift;
    return $c->stash->{cobrand} ||= $c->_get_cobrand();
}

sub _get_cobrand {
    my $c = shift;

    my $host             = $c->req->uri->host;
    my $override_moniker = $c->get_override('cobrand_moniker');

    my $cobrand_class =
      $override_moniker
      ? FixMyStreet::Cobrand->get_class_for_moniker($override_moniker)
      : FixMyStreet::Cobrand->get_class_for_host($host);

    my $cobrand = $cobrand_class->new( { c => $c } );

    return $cobrand;
}

=head2 setup_request

    $cobrand = $c->setup_request();

Work out which cobrand we should be using. Set the environment correctly - eg
template paths, maps, languages etc, etc.

=cut

sub setup_request {
    my $c = shift;

    # Set the Catalyst model schema to the same as the DB schema
    $c->model("DB")->schema( FixMyStreet::DB->schema );

    $c->setup_dev_overrides();

    my $cobrand = $c->cobrand;
    FixMyStreet::DB->schema->cobrand($cobrand);

    $cobrand->add_response_headers;

    # append the cobrand templates to the include path
    $c->stash->{additional_template_paths} = $cobrand->path_to_web_templates;

    # work out which language to use
    my $lang_override = $c->get_override('lang');
    my $host          = $c->req->uri->host;
    my $lang =
        $lang_override ? $lang_override
      : $host =~ /^(..)\./ ? $1
      : undef;
    $lang = 'en-gb' if $lang && $lang eq 'en';

    # set the language and the translation file to use - store it on stash
    my $set_lang = $cobrand->set_lang_and_domain(
        $lang,                                       # language
        1,                                           # return unicode
        FixMyStreet->path_to('locale')->stringify    # use locale directory
    );
    $c->stash->{lang_code} = $set_lang;

    # debug
    $c->log->debug( sprintf "Set lang to '%s' and cobrand to '%s'",
        $set_lang, $cobrand->moniker );

    $c->stash->{site_name} = Utils::trim_text($c->render_fragment('site-name.html'));

    if (my $template = $c->forward('/about/find_template', [ 'homepage' ])) {
        $c->stash->{homepage_template} = $template;
    }

    $c->model('DB::Problem')->set_restriction( $cobrand->site_key() );

    FixMyStreet::Map::set_map_class($cobrand);
    # All pages need this, either loading it or prefetching it
    $c->stash->{map_js} = FixMyStreet::Map::map_javascript();

    unless ( FixMyStreet->config('MAPIT_URL') ) {
        my $host_port = $c->req->uri->host_port;
        my $scheme = $c->req->uri->scheme;
        mySociety::MaPit::configure( "$scheme://$host_port/fakemapit/" );
    }

    $c->stash->{has_fixed_state} = FixMyStreet::DB::Result::Problem::fixed_states->{fixed};
    $c->cobrand->call_hook('setup_states');

    if (FixMyStreet->test_mode) {
        # Is there a better way of altering $c->config that may have
        # override_config involved?
        $c->setup_finished(0);
        $c->config( %{ FixMyStreet->config() } );
        $c->setup_finished(1);
    }

    return $c;
}

=head2 setup_dev_overrides

    $c->setup_dev_overrides();

This is only run if STAGING_SITE is true.

It is intended as an easy way to change the cobrand, language, map etc etc etc
without having to muck around with domain names and so on. The overrides are set
by passing _override_xxx parameters in the query. The values and stored in the
session and are used in preference to the defaults.

All overrides can be easily cleared by setting the _override_clear_all parameter
to true.

=cut

sub setup_dev_overrides {
    my $c = shift;

    # If not on STAGING_SITE bail out
    return unless $c->config->{STAGING_SITE};

    # Extract all the _override_xxx parameters
    my %params = %{ $c->req->parameters };
    delete $params{$_} for grep { !m{^_override_} } keys %params;

    # stop if there is nothing to add
    return unless scalar keys %params;

    # Check to see if we should clear all
    if ( $params{_override_clear_all} ) {
        delete $c->session->{overrides};
        return;
    }

    # check for all the other _override params and set their values
    my $overrides = $c->session->{overrides} ||= {};
    foreach my $raw_key ( keys %params ) {
        my ($key) = $raw_key =~ m{^_override_(.*)$};
        $overrides->{$key} = $params{$raw_key};
    }

    return $overrides;
}

=head2 get_override

    $value = $c->get_override( 'cobrand_moniker' );

Checks the overrides for the value given and returns it if found, undef if not.

Always returns undef unless on a staging site and we already have a session
(avoids autovivifying overrides hash and so creating a session for all users).

=cut

sub get_override {
    my ( $c, $key ) = @_;
    return unless $c->config->{STAGING_SITE} && $c->sessionid;
    return $c->session->{overrides}->{$key};
}

=head2 send_email

    $success = $c->send_email( 'email_template.txt', $extra_stash_values );

Send an email by filling in the given template with values in the stash.

You can specify extra values to those already in the stash by passing a hashref
as the second argument.

The stash (or extra_stash_values) keys 'to', 'from' and 'subject' are used to
set those fields in the email if they are present.

If a 'from' is not specified then the default from the config is used.

Returns the email on success, false on failure.

=cut

sub send_email {
    my $c                  = shift;
    my $template           = shift;
    my $extra_stash_values = shift || {};

    my $sender = $c->cobrand->do_not_reply_email;
    my $email = $c->construct_email($template, $extra_stash_values) or return;

    my $result = 0;
    try {
        FixMyStreet::Email::Sender->send($email, { from => $sender });
        $result = $email;
    } catch {
        my $error = $_ || 'unknown error';
        $c->log->error("$error");
    };
    return $result;
}

sub construct_email {
    my ($c, $template, $extra_stash_values) = @_;
    $extra_stash_values //= {};

    my $sender = $c->cobrand->do_not_reply_email;
    my $sender_name = $c->cobrand->contact_name;

    # create the vars to pass to the email template
    my @include_path = @{ $c->cobrand->path_to_email_templates($c->stash->{lang_code}) };
    my $vars = {
        from => [ $sender, _($sender_name) ],
        %{ $c->stash },
        additional_template_paths => \@include_path,
        %$extra_stash_values,
    };
    $vars->{site_name} = Utils::trim_text($c->view('EmailText')->render($c, 'site-name.txt', $vars));
    $vars->{signature} = $c->view('EmailText')->render($c, 'signature.txt', $vars);
    $vars->{staging} = FixMyStreet->config('STAGING_SITE');

    return if FixMyStreet::Email::is_abuser($c->model('DB')->schema, $vars->{to});

    my @inline_images;
    $vars->{inline_image} = sub { FixMyStreet::Email::add_inline_image(\@inline_images, @_); },

    my $html_template = FixMyStreet::Email::get_html_template($template, @include_path);
    my $html_compiled = eval {
        $c->view('Email')->render($c, $html_template, $vars) if $html_template;
    };
    $c->log->debug("Error compiling HTML $template: $@") if $@;

    my $data = {
        _body_ => $c->view('EmailText')->render( $c, $template, $vars ),
        _attachments_ => $extra_stash_values->{attachments},
        From => $vars->{from},
        To => $vars->{to},
        'Message-ID' => FixMyStreet::Email::message_id(),
    };
    $data->{Subject} = $vars->{subject} if $vars->{subject};
    $data->{'Reply-To'} = $vars->{'Reply-To'} if $vars->{'Reply-To'};
    $data->{_html_} = $html_compiled if $html_compiled;
    $data->{_html_images_} = \@inline_images if @inline_images;

    return mySociety::Locale::in_gb_locale { FixMyStreet::Email::construct_email($data) };
}

=head2 uri_with

    $uri = $c->uri_with( ... );

Forwards on to $c->req->uri_with, but also deletes keys that have a "" value
(as undefined is passed as that from a template).

=cut

sub uri_with {
    my $c = shift;
    my $uri = $c->req->uri_with(@_);
    my $args = $_[0];
    my %params = %{$uri->query_form_hash};
    foreach my $key (keys %$args) {
        delete $params{$key} if $args->{$key} eq "";
    }
    $uri->query_form(\%params);
    return $uri;
}

=head2 uri_for_email

    $uri = $c->uri_for_email( ... );

Like C<uri_for> except that it checks the cobrand for an email specific url base
and uses that.

=cut

sub uri_for_email {
    my $c = shift;

    my $normal_uri = $c->uri_for(@_)->absolute;
    my $base       = $c->cobrand->base_url_with_lang;

    my $email_uri = $base . $normal_uri->path_query;

    return URI->new($email_uri);
}

sub finalize {
    my $c = shift;
    $c->next::method(@_);

    # cobrand holds on to a reference to $c so we want to 
    # get git rid of this to stop circular references and
    # memory leaks
    delete $c->stash->{cobrand};
}

=head2 render_fragment

If a page needs to render a template fragment internally (e.g. for an Ajax
call), use this method.

=cut

sub render_fragment {
    my ($c, $template, $vars) = @_;
    $vars = { %{$c->stash}, %$vars } if $vars;
    $c->view('Web')->render($c, $template, $vars);
}

=head2 get_param

    $param = $c->get_param('name');

Return the parameter passed in the request, or undef if not present. Like
req->param() in a scalar context, this will return the first parameter if
multiple were provided; unlike req->param it will always return a scalar,
never a list, in order to avoid possible security issues.

=cut

sub get_param {
    my ($c, $param) = @_;
    my $value = $c->req->params->{$param};
    return $value->[0] if ref $value;
    return $value;
}

=head2 get_param_list

    @params = $c->get_param_list('name');

Return the parameters passed in the request, as a list. This will always return
a list, with an empty list if no parameter is present.

=cut

sub get_param_list {
    my ($c, $param, $allow_commas) = @_;
    die unless wantarray;
    my $value = $c->req->params->{$param};
    return () unless defined $value;
    my @value = ref $value ? @$value : ($value);
    if ($allow_commas) {
        my $csv = Text::CSV->new;
        $csv->parse(join ',', @value);
        @value = $csv->fields;
    }
    return @value;
}

=head2 set_param

    $c->set_param('name', 'My Name');

Sets the query parameter to the passed variable.

=cut

sub set_param {
    my ($c, $param, $value) = @_;
    $c->req->params->{$param} = $value;
    $c->req->body_params->{$param} = $value;
}

=head2 check_2fa

Given a user's secret, verifies a submitted code.

=cut

sub check_2fa {
    my ($c, $secret32) = @_;

    if (my $code = $c->get_param('2fa_code')) {
        my $auth = FixMyStreet::Auth::GoogleAuth->new;
        return 1 if $auth->verify($code, 2, $secret32);
        $c->stash->{incorrect_code} = 1;
    }
    return 0;
}

sub user_country {
    my $c = shift;
    return FixMyStreet::Gaze::get_country_from_ip($c->req->address);
}

=head1 SEE ALSO

L<FixMyStreet::App::Controller::Root>, L<Catalyst>

=cut

1;
