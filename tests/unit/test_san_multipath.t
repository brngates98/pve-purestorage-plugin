#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;
use PVE::Multipath::Config;

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';

my $real_remove_volume;
{
  no strict 'refs';
  $real_remove_volume = \&{"${pkg}::purestorage_remove_volume"};
}

PVE::Multipath::Config::reset_fixture();

# Pure serial → WWID uses the vendor prefix already in the plugin.
my $serial = '8476f68c18374e7700016a63';
my ( undef, $wwid ) = PVE::Storage::Custom::PureStoragePlugin::get_device_path_wwn($serial);
like( $wwid, qr/^3624a9370/, 'fixture WWID has the Pure prefix' );

subtest 'flag off or missing API does nothing' => sub {
  PVE::Multipath::Config::reset_fixture();
  ok( !$pkg->san_multipath_register_wwid( $wwid, {} ), 'no register without the flag' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'multipath.cfg stays empty' );

  ok( !$pkg->san_multipath_register_wwid( $wwid, { 'san-multipath' => 0 } ), 'flag off skips register' );
};

subtest 'register is idempotent when the flag is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  ok( $pkg->san_multipath_register_wwid( $wwid, $scfg ), 'first register succeeds' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'WWID is in multipath.cfg' );
  my $entry = PVE::Multipath::Config::read_config()->{ids}->{$wwid};
  ok( !exists $entry->{'paths-expected'}, 'no paths-expected on auto entries' );

  ok( $pkg->san_multipath_register_wwid( $wwid, $scfg ), 'second register is still ok' );
  is( scalar keys %{ PVE::Multipath::Config::read_config()->{ids} }, 1, 'still one entry' );
};

subtest 'unregister removes the entry when the flag is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  $pkg->san_multipath_register_wwid( $wwid, $scfg );
  ok( $pkg->san_multipath_unregister_wwid( $wwid, $scfg ), 'unregister succeeds' );
  ok( !exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'WWID is gone' );
  ok( $pkg->san_multipath_unregister_wwid( $wwid, $scfg ), 'unregister of a missing entry is ok' );
};

subtest 'alloc_image registers when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::purestorage_create_volume"} = sub {
      return $serial;
    };
  }
  my $name = $plugin->alloc_image( 'pure', { 'san-multipath' => 1 }, 100, 'raw', 'vm-100-disk-0.raw', 1024 );
  is( $name, 'vm-100-disk-0', 'alloc still returns the volume name' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'alloc registered the WWID' );
};

subtest 'activate_volume registers lazily when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::purestorage_volume_connection"} = sub { return 1 };
    *{"${pkg}::map_volume"} = sub { return ( '/dev/x', $wwid ) };
  }
  ok( $plugin->activate_volume( 'pure', { 'san-multipath' => 1 }, 'vm-100-disk-0' ), 'activate succeeds' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'activate registered the WWID from map_volume' );
};

subtest 'free_image unregisters after remove when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  $pkg->san_multipath_register_wwid( $wwid, $scfg );
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::deactivate_volume"}         = sub { return 1 };
    *{"${pkg}::purestorage_get_wwn"}       = sub { return ( '/dev/x', $wwid ) };
    *{"${pkg}::purestorage_remove_volume"} = sub { return $serial };
  }
  $plugin->free_image( 'pure', $scfg, 'vm-100-disk-0' );
  ok( !exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'free_image removed the WWID entry' );
};

subtest 'free_image unregisters using serial from remove when get_wwn fails' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  $pkg->san_multipath_register_wwid( $wwid, $scfg );
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::deactivate_volume"}         = sub { return 1 };
    *{"${pkg}::purestorage_get_wwn"}       = sub { return ( '', '' ) };
    *{"${pkg}::purestorage_remove_volume"} = sub { return $serial };
  }
  $plugin->free_image( 'pure', $scfg, 'vm-100-disk-0' );
  ok( !exists PVE::Multipath::Config::read_config()->{ids}->{$wwid},
    'serial from remove_volume still clears the multipath.cfg entry' );
};

subtest 'empty WWID is ignored' => sub {
  PVE::Multipath::Config::reset_fixture();
  ok( !$pkg->san_multipath_register_wwid( '', { 'san-multipath' => 1 } ), 'empty WWID does not register' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'cfg unchanged' );
};

subtest 'registration errors do not fail activate or clone' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::purestorage_volume_connection"} = sub { return 1 };
    *{"${pkg}::map_volume"}                    = sub { return ( '/dev/x', $wwid ) };
    *{"${pkg}::purestorage_get_wwn"}           = sub { die "array unreachable\n" };
    *{"${pkg}::purestorage_volume_restore"}    = sub { return 1 };
    *{"${pkg}::find_free_diskname"}            = sub { return 'vm-200-disk-0' };
  }
  local $PVE::Multipath::Config::FAIL = "lock unavailable\n";
  ok( $plugin->activate_volume( 'pure', { 'san-multipath' => 1 }, 'vm-100-disk-0' ),
    'activate succeeds when multipath.cfg lock fails during registration' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'no entry after failed registration' );
  $PVE::Multipath::Config::FAIL = undef;

  my $clone = eval { $plugin->clone_image( { 'san-multipath' => 1 }, 'pure', 'vm-100-disk-0', 200, 'snap1' ) };
  is( $clone, 'vm-200-disk-0', 'clone succeeds when SAN registration cannot resolve the WWID' );
  is( $@, '', 'clone does not die from SAN registration failure' );
};

subtest 'lock failure is soft' => sub {
  PVE::Multipath::Config::reset_fixture();
  local $PVE::Multipath::Config::FAIL = "lock unavailable\n";
  ok( !$pkg->san_multipath_register_wwid( $wwid, { 'san-multipath' => 1 } ), 'register returns false on lock failure' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'cfg unchanged after lock failure' );
};

subtest 'remove_volume tolerates a missing volume info answer' => sub {
  my @calls;
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::purestorage_remove_volume"}   = $real_remove_volume;
    *{"${pkg}::purestorage_get_volume_info"} = sub { return undef };
    *{"${pkg}::purestorage_api_call"}        = sub {
      my ( $scfg, $action ) = @_;
      push @calls, $action->{name};
      return { items => [] };
    };
  }
  my $got = eval { $pkg->purestorage_remove_volume( {}, 'vm-100-disk-0', 'pure' ) };
  is( $@,   '', 'remove does not die when volume info is undef' );
  is( $got, '', 'serial is empty when volume info was missing' );
  ok( scalar( grep { $_ eq 'destroy volume' } @calls ), 'array destroy still runs' );
};

done_testing;
