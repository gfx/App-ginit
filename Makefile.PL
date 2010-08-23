use inc::Module::Install;
use Module::Install::AuthorTests;
use Module::Install::Repository;

all_from 'lib/App/ginit.pm';

requires_external_bin 'git';
requires_external_bin 'tar';
requires_external_bin 'unzip';

test_requires 'Test::More';

tests_recursive;
author_tests 'xt';

install_script;

auto_set_repository;

WriteAll(check_nmake => 0);
