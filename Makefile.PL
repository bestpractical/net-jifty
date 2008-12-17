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

build_requires  'Test::More';
build_requires  'Test::MockObject';

features(
    'Date loading' => [
        -default => 0,
       recommends( 'DateTime')
    ],
    'Cascading directory config' => [
        -default => 0,
        recommends('Hash::Merge'),
        recommends('Path::Class'),
        recommends('Cwd'),
    ],
);

WriteAll;

