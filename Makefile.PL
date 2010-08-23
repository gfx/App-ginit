use inc::Module::Install;
name 'App-ginit';
all_from 'lib/App/ginit.pm';

# requires '';

tests 't/*.t';
author_tests 'xt';

test_requires 'Test::More';
auto_set_repository;
auto_include;
WriteAll;
