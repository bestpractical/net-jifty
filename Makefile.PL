use inc::Module::Install;

name            'Net-Jifty';
all_from        'lib/Net/Jifty.pm';

requires        'Moose' => '0.50';
requires        'LWP::UserAgent';
requires        'YAML';
requires        'URI';
requires        'Encode';
requires        'Email::Address';
requires        'Term::ReadKey';
requires        'Path::Class';
requires        'Cwd';
requires        'Hash::Merge';

build_requires  'Test::More';
build_requires  'Test::MockObject';

features(
    'Date loading' => [
        -default => 0,
       recommends( 'DateTime')
    ],
);

WriteAll;

