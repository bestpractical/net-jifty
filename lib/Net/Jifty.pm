#!/usr/bin/env perl
package Net::Jifty;
use Moose;
use Net::Jifty::Record;

use LWP::UserAgent;
use HTTP::Request;
use URI;

use YAML;
use Hash::Merge;

use Encode;
use Fcntl qw(:mode);

use Cwd;
use Path::Class;

use DateTime;
use Email::Address;

=head1 NAME

Net::Jifty - interface to online Jifty applications

=head1 VERSION

Version 0.07 released ???

=cut

our $VERSION = '0.07';

=head1 SYNOPSIS

    use Net::Jifty;
    my $j = Net::Jifty->new(
        site        => 'http://mushroom.mu/',
        cookie_name => 'MUSHROOM_KINGDOM_SID',
        email       => 'god@mushroom.mu',
        password    => 'melange',
    );

    # the story begins
    $j->create(Hero => name => 'Mario', job => 'Plumber');

    # find the hero whose job is Plumber and change his name to Luigi
    # and color to green
    $j->update(Hero => job => 'Plumber',
        name  => 'Luigi',
        color => 'Green',
    );

    # win!
    $j->delete(Enemy => name => 'Bowser');

=head1 DESCRIPTION

L<Jifty> is a full-stack web framework. It provides an optional REST interface
for applications. Using this module, you can interact with that REST
interface to write client-side utilities.

You can use this module directly, but you'll be better off subclassing it, such
as what we've done for L<Net::Hiveminder>.

This module also provides a number of convenient methods for writing short
scripts. For example, passing C<< use_config => 1 >> to C<new> will look at
the config file for the username and password (or SID) of the user. If neither
is available, it will prompt the user for them.

=cut

has site => (
    is            => 'rw',
    isa           => 'Str',
    required      => 1,
    documentation => "The URL of your application",
    trigger       => sub {
        # this canonicalizes localhost to 127.0.0.1 because of an (I think)
        # HTTP::Cookies bug. cookies aren't sent out for localhost.
        my ($self, $site, $attr) = @_;

        if ($site =~ s/\blocalhost\b/127.0.0.1/) {
            $attr->set_value($self, $site);
        }
    },
);

has cookie_name => (
    is            => 'rw',
    isa           => 'Str',
    required      => 1,
    documentation => "The name of the session ID cookie. This can be found in your config under Framework/Web/SessinCookieName",
);

has appname => (
    is            => 'rw',
    isa           => 'Str',
    documentation => "The name of the application, as it is known to Jifty",
);

has email => (
    is            => 'rw',
    isa           => 'Str',
    documentation => "The email address to use to log in",
);

has password => (
    is            => 'rw',
    isa           => 'Str',
    documentation => "The password to use to log in",
);

has sid => (
    is  => 'rw',
    isa => 'Str',
    documentation => "The session ID, from the cookie_name cookie. You can use this to bypass login",
    trigger => sub {
        my $self = shift;

        my $uri = URI->new($self->site);
        $self->ua->cookie_jar->set_cookie(0, $self->cookie_name,
                                          $self->sid, '/',
                                          $uri->host, $uri->port,
                                          0, 0, undef, 1);
    },
);

has ua => (
    is      => 'rw',
    isa     => 'LWP::UserAgent',
    default => sub {
        my $args = shift;

        my $ua = LWP::UserAgent->new;

        $ua->cookie_jar({});
        push @{ $ua->requests_redirectable }, qw( POST PUT DELETE );

        # Load the user's proxy settings from %ENV
        $ua->env_proxy;

        return $ua;
    },
);

has config_file => (
    is            => 'rw',
    isa           => 'Str',
    default       => "$ENV{HOME}/.jifty",
    documentation => "The place to look for the user's config file",
);

has use_config => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    documentation => "Whether or not to use the user's config",
);

has config => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
    documentation => "Storage for the user's config",
);

has use_filters => (
    is            => 'rw',
    isa           => 'Bool',
    default       => 1,
    documentation => "Whether or not to use config files in the user's directory tree",
);

has filter_file => (
    is            => 'rw',
    isa           => 'Str',
    default       => ".jifty",
    documentation => "The filename to look for in each parent directory",
);

has strict_arguments => (
    is            => 'rw',
    isa           => 'Bool',
    default       => 0,
    documentation => "Check to make sure mandatory arguments are provided, and no unknown arguments are included",
);

has action_specs => (
    is            => 'rw',
    isa           => 'HashRef[HashRef]',
    default       => sub { {} },
    documentation => "The cache for action specifications",
);

has model_specs => (
    is            => 'rw',
    isa           => 'HashRef[HashRef]',
    default       => sub { {} },
    documentation => "The model for action specifications",
);

=head2 BUILD

Each L<Net::Jifty> object will do the following upon creation:

=over 4

=item Read config

..but only if you C<use_config> is set to true.

=item Log in

..unless a sid is available, in which case we're already logged in.

=back

=cut

sub BUILD {
    my $self = shift;

    $self->load_config
        if $self->use_config && $self->config_file;

    $self->login
        unless $self->sid;
}

=head2 login

This assumes your site is using L<Jifty::Plugin::Authentication::Password>.
If that's not the case, override this in your subclass.

This is called automatically when each L<Net::Jifty> object is constructed
(unless a session ID is passed in).

=cut

sub login {
    my $self = shift;

    return if $self->sid;

    confess "Unable to log in without an email and password."
        unless $self->email && $self->password;

    confess 'Your email did not contain an "@" sign. Did you accidentally use double quotes?'
        if $self->email !~ /@/;

    my $result = $self->call(Login =>
                                address  => $self->email,
                                password => $self->password);

    confess "Unable to log in."
        if $result->{failure};

    $self->get_sid;
    return 1;
}

=head2 call ACTION, ARGS

This uses the Jifty "web services" API to perform C<ACTION>. This is I<not> the
REST interface, though it resembles it to some degree.

This module currently only uses this to log in.

=cut

sub call {
    my $self    = shift;
    my $action  = shift;
    my %args    = @_;
    my $moniker = 'fnord';

    my $res = $self->ua->post(
        $self->site . "/__jifty/webservices/yaml",
        {   "J:A-$moniker" => $action,
            map { ( "J:A:F-$_-$moniker" => $args{$_} ) } keys %args
        }
    );

    if ( $res->is_success ) {
        return YAML::Load( Encode::decode_utf8($res->content) )->{$moniker};
    } else {
        confess $res->status_line;
    }
}

=head2 form_url_encoded_args ARGS

This will take a hash containing arguments and convert those arguments into URL encoded form. I.e., (x => 1, y => 2, z => 3) becomes:

  x=1&y=2&z=3

These are then ready to be appened to the URL on a GET or placed into the content of a PUT.

=cut

sub form_url_encoded_args {
    my $self = shift;

    my $uri = '';
    while (my ($key, $value) = splice @_, 0, 2) {
        $uri .= join('=', map { $self->escape($_) } $key, $value) . '&';
    }
    chop $uri;

    return $uri;
}

=head2 method METHOD, URL[, ARGS]

This will perform a GET, POST, PUT, DELETE, etc using the internal
L<LWP::UserAgent> object.

C<URL> may be a string or an array reference (which will have its parts
properly escaped and joined with C</>). C<URL> already has
C<http://your.site/=/> prepended to it, and C<.yml> appended to it, so you only
need to pass something like C<model/YourApp.Model.Foo/name>, or
C<[qw/model YourApp.Model.Foo name]>.

This will return the data structure returned by the Jifty application, or throw
an error.

=cut

sub method {
    my $self   = shift;
    my $method = lc(shift);
    my $url    = shift;
    my @args   = @_;

    $url = $self->join_url(@$url)
        if ref($url) eq 'ARRAY';

    # remove trailing /
    $url =~ s{/+$}{};

    my $uri = $self->site . '/=/' . $url . '.yml';

    my $res;

    if ($method eq 'get' || $method eq 'head') {
        $uri .= '?' . $self->form_url_encoded_args(@args)
            if @args;

        $res = $self->ua->$method($uri);
    }
    else {
        my $req = HTTP::Request->new(
            uc($method) => $uri,
        );

        if (@args) {
            my $content = $self->form_url_encoded_args(@args);
            $req->header('Content-type' => 'application/x-www-form-urlencoded');
            $req->content($content);
        }

        $res = $self->ua->request($req);

        # XXX Compensation for a bug in Jifty::Plugin::REST... it doesn't
        # remember to add .yml when redirecting after an update, so we will
        # try to do that ourselves... fixed in a Jifty coming to stores near
        # you soon!
        if ($res->is_success && $res->content_type eq 'text/html') {
            $req = $res->request->clone;
            $req->uri($req->uri . '.yml');
            $res = $self->ua->request($req);
        }
    }

    if ($res->is_success) {
        return YAML::Load( Encode::decode_utf8($res->content) );
    } else {
        confess $res->status_line;
    }
}

=head2 post URL, ARGS

This will post C<ARGS> to C<URL>. See the documentation for C<method> about
the format of C<URL>.

=cut

sub post {
    my $self = shift;
    $self->method('post', @_);
}

=head2 get URL, ARGS

This will get the specified C<URL> with C<ARGS> as query parameters. See the
documentation for C<method> about the format of C<URL>.

=cut

sub get {
    my $self = shift;
    $self->method('get', @_);
}

=head2 act ACTION, ARGS

Perform C<ACTION>, using C<ARGS>. This does use the REST interface.

=cut

sub act {
    my $self   = shift;
    my $action = shift;

    $self->validate_action_args($action => @_)
        if $self->strict_arguments;

    return $self->post(["action", $action], @_);
}

=head2 create MODEL, FIELDS

Create a new object of type C<MODEL> with the C<FIELDS> set.

=cut

sub create {
    my $self  = shift;
    my $model = shift;

    $self->validate_action_args([create => $model] => @_)
        if $self->strict_arguments;

    return $self->post(["model", $model], @_);
}

=head2 delete MODEL, KEY => VALUE

Find some C<MODEL> where C<KEY> is C<VALUE> and delete it.

=cut

sub delete {
    my $self   = shift;
    my $model  = shift;
    my $key    = shift;
    my $value  = shift;

    $self->validate_action_args([delete => $model] => $key => $value)
        if $self->strict_arguments;

    return $self->method(delete => ["model", $model, $key, $value]);
}

=head2 update MODEL, KEY => VALUE, FIELDS

Find some C<MODEL> where C<KEY> is C<VALUE> and set C<FIELDS> on it.

=cut

sub update {
    my $self   = shift;
    my $model  = shift;
    my $key    = shift;
    my $value  = shift;

    $self->validate_action_args([update => $model] => $key => $value, @_)
        if $self->strict_arguments;

    return $self->method(put => ["model", $model, $key, $value], @_);
}

=head2 read MODEL, KEY => VALUE

Find some C<MODEL> where C<KEY> is C<VALUE> and return it.

=cut

sub read {
    my $self   = shift;
    my $model  = shift;
    my $key    = shift;
    my $value  = shift;

    return $self->get(["model", $model, $key, $value]);
}

=head2 search MODEL, FIELDS[, OUTCOLUMN]

Searches for all objects of type C<MODEL> that satisfy C<FIELDS>. The optional
C<OUTCOLUMN> defines the output column, in case you don't want the entire
records.

=cut

sub search {
    my $self  = shift;
    my $model = shift;
    my @args;

    while (@_) {
        if (@_ == 1) {
            push @args, shift;
        }
        else {
            # id => [1,2,3] maps to id/1/id/2/id/3
            if (ref($_[1]) eq 'ARRAY') {
                push @args, map { $_[0] => $_ } @{ $_[1] };
                splice @_, 0, 2;
            }
            else {
                push @args, splice @_, 0, 2;
            }
        }
    }

    return $self->get(["search", $model, @args]);
}

=head2 validate_action_args action => args

Validates the given action, to check to make sure that all mandatory arguments
are given and that no unknown arguments are given.

You may give action as a string, which will be interpreted as the action name;
or as an array reference for CRUD - the first element will be the action
(create, update, or delete) and the second element will be the model name.

This will throw an error or if validation succeeds, will return 1.

=cut

sub validate_action_args {
    my $self   = shift;
    my $action = shift;
    my %args   = @_;

    my $name;
    if (ref($action) eq 'ARRAY') {
        my ($operation, $model) = @$action;

        # drop MyApp::Model::
        $model =~ s/.*:://;

        confess "Invalid model operation: $operation. Expected 'create', 'update', or 'delete'." unless $operation =~ m{^(?:create|update|delete)$}i;

        $name = ucfirst(lc $operation) . $model;
    }
    else {
        $name = $action;
    }

    my $action_spec = $self->get_action_spec($name);

    for my $arg (keys %$action_spec) {
        confess "Mandatory argument '$arg' not given for action $name."
            if $action_spec->{$arg}{mandatory} && !defined($args{$arg});
        delete $args{$arg};
    }

    if (keys %args) {
        confess "Unknown arguments given for action $name: "
              . join(', ', keys %args);
    }

    return 1;
}

=head2 get_action_spec action_name

Returns the action spec (which arguments it takes, and metadata about them).
The first request for a particular action will ask the server for the spec.
Subsequent requests will return it from the cache.

=cut

sub get_action_spec {
    my $self = shift;
    my $name = shift;

    unless ($self->action_specs->{$name}) {
        $self->action_specs->{$name} = $self->get("action/$name");
    }

    return $self->action_specs->{$name};
}

=head2 get_model_spec model_name

Returns the model spec (which columns it has).  The first request for a
particular model will ask the server for the spec.  Subsequent requests will
return it from the cache.

=cut

sub get_model_spec {
    my $self = shift;
    my $name = shift;

    unless ($self->model_specs->{$name}) {
        $self->model_specs->{$name} = $self->get("model/$name");
    }

    return $self->model_specs->{$name};
}

=head2 get_sid

Retrieves the sid from the L<LWP::UserAgent> object.

=cut

sub get_sid {
    my $self = shift;
    my $cookie = $self->cookie_name;

    my $sid;
    $sid = $1
        if $self->ua->cookie_jar->as_string =~ /\Q$cookie\E=([^;]+)/;

    $self->sid($sid);
}

=head2 join_url FRAGMENTS

Encodes C<FRAGMENTS> and joins them with C</>.

=cut

sub join_url {
    my $self = shift;

    return join '/', map { $self->escape($_) } grep { defined } @_
}

=head2 escape STRINGS

Returns C<STRINGS>, properly URI-escaped.

=cut

sub escape {
    my $self = shift;

    return map { s/([^a-zA-Z0-9_.!~*'()-])/uc sprintf("%%%02X", ord $1)/eg; $_ }
           map { Encode::encode_utf8($_) }
           @_
}

=head2 load_date DATE

Loads C<DATE> (which must be of the form C<YYYY-MM-DD>) into a L<DateTime>
object.

=cut

sub load_date {
    my $self = shift;
    my $ymd  = shift;

    my ($y, $m, $d) = $ymd =~ /^(\d\d\d\d)-(\d\d)-(\d\d)(?: 00:00:00)?$/
        or confess "Invalid date passed to load_date: $ymd. Expected yyyy-mm-dd.";

    return DateTime->new(
        time_zone => 'floating',
        year      => $y,
        month     => $m,
        day       => $d,
    );
}

=head2 email_eq EMAIL, EMAIL

Compares the two email addresses. Returns true if they're equal, false if
they're not.

=cut

sub email_eq {
    my $self = shift;
    my $a    = shift;
    my $b    = shift;

    # if one's defined and the other isn't, return 0
    return 0 unless (defined $a ? 1 : 0)
                 == (defined $b ? 1 : 0);

    return 1 if !defined($a) && !defined($b);

    # so, both are defined

    for ($a, $b) {
        $_ = 'nobody@localhost' if $_ eq 'nobody' || /<nobody>/;
        my ($email) = Email::Address->parse($_);
        $_ = lc($email->address);
    }

    return $a eq $b;
}

=head2 is_me EMAIL

Returns true if C<EMAIL> looks like it is the same as the current user's.

=cut

sub is_me {
    my $self = shift;
    my $email = shift;

    return 0 if !defined($email);

    return $self->email_eq($self->email, $email);
}

=head2 load_config

This will return a hash reference of the user's preferences. Because this
method is designed for use in small standalone scripts, it has a few
peculiarities.

=over 4

=item

It will C<warn> if the permissions are too liberal on the config file, and fix
them.

=item

It will prompt the user for an email and password if necessary. Given
the email and password, it will attempt to log in using them. If that fails,
then it will try again.

=item

Upon successful login, it will write a new config consisting of the options
already in the config plus session ID, email, and password.

=back

=cut

sub load_config {
    my $self = shift;

    $self->config_permissions;
    $self->read_config_file;

    # allow config to override everything. this may need to be less free in
    # the future
    while (my ($key, $value) = each %{ $self->config }) {
        $self->$key($value)
            if $self->can($key);
    }

    $self->prompt_login_info
        unless $self->config->{email} || $self->config->{sid};

    # update config if we are logging in manually
    unless ($self->config->{sid}) {

        # if we have user/pass in the config then we still need to log in here
        unless ($self->sid) {
            $self->login;
        }

        # now write the new config
        $self->config->{sid} = $self->sid;
        $self->write_config_file;
    }

    return $self->config;
}

=head2 config_permissions

This will warn about (and fix) config files being readable by group or others.

=cut

sub config_permissions {
    my $self = shift;
    my $file = $self->config_file;

    return if $^O eq 'MSWin32';
    return unless -e $file;
    my @stat = stat($file);
    my $mode = $stat[2];
    if ($mode & S_IRGRP || $mode & S_IROTH) {
        warn "Config file $file is readable by users other than you, fixing.";
        chmod 0600, $file;
    }
}

=head2 read_config_file

This transforms the config file into a hashref. It also does any postprocessing
needed, such as transforming localhost to 127.0.0.1 (due to an obscure bug,
probably in HTTP::Cookies).

=cut

sub read_config_file {
    my $self = shift;
    my $file = $self->config_file;

    return unless -e $file;

    $self->config(YAML::LoadFile($self->config_file) || {});

    if ($self->config->{site}) {
        # Somehow, localhost gets normalized to localhost.localdomain,
        # and messes up HTTP::Cookies when we try to set cookies on
        # localhost, since it doesn't send them to
        # localhost.localdomain.
        $self->config->{site} =~ s/localhost/127.0.0.1/;
    }
}

=head2 write_config_file

This will write the config to disk. This is usually only done when a sid is
discovered, but may happen any time.

=cut

sub write_config_file {
    my $self = shift;
    my $file = $self->config_file;

    YAML::DumpFile($file, $self->config);
    chmod 0600, $file;
}

=head2 prompt_login_info

This will ask the user for her email and password. It may do so repeatedly
until login is successful.

=cut

sub prompt_login_info {
    my $self = shift;

    print << "END_WELCOME";
Before we get started, please enter your @{[ $self->site ]}
username and password.

This information will be stored in @{[ $self->config_file ]},
should you ever need to change it.

END_WELCOME

    local $| = 1; # Flush buffers immediately

    while (1) {
        print "First, what's your email address? ";
        $self->config->{email} = <STDIN>;
        chomp($self->config->{email});

        require Term::ReadKey;
        print "And your password? ";
        Term::ReadKey::ReadMode('noecho');
        $self->config->{password} = <STDIN>;
        chomp($self->config->{password});
        Term::ReadKey::ReadMode('restore');

        print "\n";

        $self->email($self->config->{email});
        $self->password($self->config->{password});

        last if eval { $self->login };

        $self->email('');
        $self->password('');

        print "That combination doesn't seem to be correct. Try again?\n";
    }
}

=head2 filter_config [DIRECTORY] -> HASH

Looks at the (given or) current directory, and all parent directories, for
files named C<< $self->filter_file >>. Each file is YAML. The contents of the
files will be merged (such that child settings override parent settings), and
the merged hash will be returned.

What this is used for is up to the application or subclasses. L<Net::Jifty>
doesn't look at this at all, but it may in the future (such as for email and
password).

=cut

sub filter_config {
    my $self = shift;

    return {} unless $self->use_filters;

    my $all_config = {};

    my $dir = dir(shift || getcwd);

    my $old_behavior = Hash::Merge::get_behavior;
    Hash::Merge::set_behavior('RIGHT_PRECEDENT');

    while (1) {
        my $file = $dir->file( $self->filter_file )->stringify;

        if (-r $file) {
            my $this_config = YAML::LoadFile($file);
            $all_config = Hash::Merge::merge($this_config, $all_config);
        }

        my $parent = $dir->parent;
        last if $parent eq $dir;
        $dir = $parent;
    }

    Hash::Merge::set_behavior($old_behavior);

    return $all_config;
}

=head2 email_of ID

Retrieve user C<ID>'s email address.

=cut

sub email_of {
    my $self = shift;
    my $id = shift;

    my $user = $self->read(User => id => $id);
    return $user->{email};
}

=head2 create_model_class Name -> ClassName

Creates a new model class for the given Name.

=cut

sub create_model_class {
    my $self  = shift;
    my $model = shift;

    my $class = $self->name_model_class($model);

    if ($class->can('_net_jifty_model_class_created')) {
        return $class->meta->name;
    }

    # retrieve and massage spec from the server..
    my $spec = $self->get_model_spec($model);
    my ($attributes, $methods) = $self->_moosify_columns($spec);

    if ($class->can('meta')) {
        $class->meta->make_mutable;
    }

    my $meta = Moose::Meta::Class->create(
        $class,
        superclasses => ['Net::Jifty::Record'],
        attributes   => $attributes,
        methods      => {
            %$methods,
            _net_jifty_model_class_created => sub { 1 },
        },
    );

    for my $attribute (@$attributes) {
        my $name   = $attribute->name;
        my $reader = $attribute->get_read_method;
        my $writer = $attribute->get_write_method;

        next unless $reader && $writer;

        $meta->add_after_method_modifier($writer => sub {
            my $self = shift;
            return if @_ == 0; # read
            $self->update($name, $self->$reader);
        });
    }

    $meta->add_attribute('+_model_class',
        default => $model,
    );

    $meta->make_immutable;

    return $meta->name;
}

sub _moosify_columns {
    my $self = shift;
    my $model_spec = shift;
    my @attributes;
    my %methods;

    for my $column (keys %$model_spec) {
        next if $column eq 'id'; # already taken care of
        my $spec = $model_spec->{$column};
        my %opts;

        # the key name. this may be different for refers columns
        $opts{init_arg} = $column;

        $opts{is} = $spec->{readable} && $spec->{writable} ? 'rw'
                  : $spec->{readable}                      ? 'ro'
                  : undef;
        $opts{isa} = $self->_moosify_type($spec->{type});
        delete $opts{isa} if !defined($opts{isa});

        $opts{required} = $spec->{mandatory};

        if ($spec->{refers_to}) {
            my %refer_opts;
            $spec->{by} ||= 'id';

            # end up with column=owner_id and refer_name=owner
            $column =~ s/_id$//;
            my $refer_name = $column;
            $column .= $spec->{by};

            $refer_opts{lazy} = 1;
            $refer_opts{isa} = $spec->{refers_to};
            my ($refer_class, $refer_by) = ($opts{isa}, $spec->{by});

            $refer_opts{default} = sub {
                my $self  = shift;
                my $class = $self->_interface->create_model_class($refer_class);

                # get the scalar referral value (probably the numeric ID)
                my $attr  = $self->meta->get_attribute($column);
                my $value = $attr->get_read_method_ref->($self);

                $class->load($self->_interface, $refer_by, $value);
            };
            push @attributes, Moose::Meta::Attribute->new($refer_name, %refer_opts);
        }

        push @attributes, Moose::Meta::Attribute->new($column, %opts);
    }

    return (\@attributes, \%methods);
}

my %types = (
    serial => 'Int',
);

sub _moosify_type {
    my $self = shift;
    my $type = lc(shift);

    return $types{$type} if exists $types{$type};

    return 'Int'  if $type =~ /int/;
    return 'Str'  if $type =~ /char|text/;
    return 'Num'  if $type =~ /numeric|decimal|real|double|float/;
    return 'Bool' if $type =~ /bool/;

    Carp::carp "Unhandled type: $type";
    return undef;
}

sub name_model_class {
    my $self  = shift;
    my $model = shift;

    my ($last) = $model =~ /.*::(.*)/;
    $last = $model if !$last; # no ::

    if (blessed($self) eq 'Net::Jifty') {
        return "Net::Jifty::Record::$last";
    }

    return blessed($self) . "::$last";
}

=head1 SEE ALSO

L<Jifty>, L<Net::Hiveminder>

=head1 AUTHOR

Shawn M Moore, C<< <sartak at bestpractical.com> >>

=head1 CONTRIBUTORS

Andrew Sterling Hanenkamp, C<< <hanenkamp@gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-net-jifty at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-Jifty>.

=head1 COPYRIGHT & LICENSE

Copyright 2007 Best Practical Solutions.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;
no Moose;

1;

