# ${license-info}
# ${developer-info}
# ${author-info}
# ${build-info}


# This component needs a 'ceph' user. 
# The user should be able to run these commands with sudo without password:
# /usr/bin/ceph-deploy
# /usr/bin/python -c import sys;exec(eval(sys.stdin.readline()))
# /usr/bin/python -u -c import sys;exec(eval(sys.stdin.readline()))
# /bin/mkdir
#

package NCM::Component::Ceph::daemon;

use 5.10.1;
use strict;
use warnings;

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

use LC::Exception;
use LC::Find;

use Data::Dumper;
use EDG::WP4::CCM::Element qw(unescape);
use File::Basename;
use File::Copy qw(copy move);
use JSON::XS;
use Readonly;
use Socket;
our $EC=LC::Exception::Context->new->will_store_all;
Readonly my $OSDBASE => qw(/var/lib/ceph/osd/);
Readonly my $JOURNALBASE => qw(/var/lib/ceph/log/);


# get host of ip; save the map to avoid repetition
sub get_host {
    my ($self, $ip) = @_;
    if (!$self->{_hostmap}) {
        $self->{_hostmap} = {};
    }
    if (!$self->{_hostmap}->{$ip}) {
        $self->{_hostmap}->{$ip} = gethostbyaddr(Socket::inet_aton($ip), Socket::AF_INET());
        $self->debug(3, "host of $ip is $self->{_hostmap}->{$ip}");
    }
    return $self->{_hostmap}->{$ip};
}
    
# Gets the OSD map
sub osd_hash {
    my ($self) = @_;
    my $jstr = $self->run_ceph_command([qw(osd tree)]) or return 0;
    my $osdtree = decode_json($jstr);
    $jstr = $self->run_ceph_command([qw(osd dump)]) or return 0;
    my $osddump = decode_json($jstr);  
    my %osdparsed = ();
    foreach my $osd (@{$osddump->{osds}}) {
        my $id = $osd->{osd};
        my ($name,$host);
        $name = "osd.$id";
        my @addr = split(':', $osd->{public_addr});
        my $ip = $addr[0];
        $host = $self->get_host($ip);
        if (!$host) {
            $self->error("Parsing osd commands went wrong: Could not retrieve fqdn of ip $ip.");
            return 0;
        }
        my @fhost = split('\.', $host);
        $host = $fhost[0];
        my ($osdloc, $journalloc) = $self->get_osd_location($id, $ip, $osd->{uuid}) or return 0;
        my $osdp = { 
            name            => $name, 
            host            => $host, 
            ip              => $ip, 
            id              => $id, 
            uuid            => $osd->{uuid}, 
            up              => $osd->{up}, 
            in              => $osd->{in}, 
            osd_path        => $osdloc, 
            journal_path    => $journalloc 
        };
        my $osdstr = "$host:$osdloc";
        $osdparsed{$osdstr} = $osdp;
    }
    return \%osdparsed;
}

# checks whoami,fsid and ceph_fsid and returns the real path
sub get_osd_location {
    my ($self,$osd, $host, $uuid) = @_;
    my $osdlink = "/var/lib/ceph/osd/$self->{clname}-$osd";
    if (!$host) {
        $self->error("Can not find osd without a hostname");
        return ;
    }   
    
    # TODO: check if physical exists?
    my @catcmd = ('/usr/bin/ssh', $host, 'cat');
    my $ph_uuid = $self->run_command_as_ceph([@catcmd, $osdlink . '/fsid']);
    chomp($ph_uuid);
    if ($uuid ne $ph_uuid) {
        $self->error("UUID for osd.$osd of ceph command output differs from that on the disk. ",
            "Ceph value: $uuid, ", 
            "Disk value: $ph_uuid");
        return ;    
    }
    my $ph_fsid = $self->run_command_as_ceph([@catcmd, $osdlink . '/ceph_fsid']);
    chomp($ph_fsid);
    my $fsid = $self->{fsid};
    if ($ph_fsid ne $fsid) {
        $self->error("fsid for osd.$osd not matching with this cluster! ", 
            "Cluster value: $fsid, ", 
            "Disk value: $ph_fsid");
        return ;
    }
    my @loccmd = ('/usr/bin/ssh', $host, '/bin/readlink');
    my $osdloc = $self->run_command_as_ceph([@loccmd, $osdlink]);
    my $journalloc = $self->run_command_as_ceph([@loccmd, '-f', "$osdlink/journal" ]);
    chomp($osdloc);
    chomp($journalloc);
    return $osdloc, $journalloc;

}

# Checks if the disk is empty
sub check_empty {
    my ($self, $loc, $host) = @_;

    my @lscmd = ('/usr/bin/ssh', $host, 'ls', '-1', $loc);
    my $lsoutput = $self->run_command_as_ceph([@lscmd]) or return 0;
    my $lines = $lsoutput =~ tr/\n//;
    if ($lines != 0) {
        $self->error("$loc on $host is not empty!");
        return 0;
    } else {
        return 1;
    }    
}

# Gets the MON map
sub mon_hash {
    my ($self) = @_;
    my $jstr = $self->run_ceph_command([qw(mon dump)]) or return 0;
    my $monsh = decode_json($jstr);
    $jstr = $self->run_ceph_command([qw(quorum_status)]) or return 0;
    my $monstate = decode_json($jstr);
    my %monparsed = ();
    foreach my $mon (@{$monsh->{mons}}){
        $mon->{up} = $mon->{name} ~~ @{$monstate->{quorum_names}};
        $monparsed{$mon->{name}} = $mon; 
    }
    return \%monparsed;
}

# Gets the MDS map 
sub mds_hash {
    my ($self) = @_;
    my $jstr = $self->run_ceph_command([qw(mds stat)]) or return 0;
    my $mdshs = decode_json($jstr);
    my %mdsparsed = ();
    foreach my $mds (values %{$mdshs->{mdsmap}->{info}}) {
        my @state = split(':', $mds->{state});
        my $up = ($state[0] eq 'up') ? 1 : 0 ;
        my $mdsp = {
            name => $mds->{name},
            gid => $mds->{gid},
            up => $up
        };
        $mdsparsed{$mds->{name}} = $mdsp;
    }
    return \%mdsparsed;
}       

## Processing and comparing between Quattor and Ceph

# Do a comparison of quattor config and the actual ceph config 
# for a given type (cfg, mon, osd, mds)
sub ceph_quattor_cmp {
    my ($self, $type, $quath, $cephh) = @_;
    foreach my $qkey (sort(keys %{$quath})) {
        if (exists $cephh->{$qkey}) {
            my $pair = [$quath->{$qkey}, $cephh->{$qkey}];
            #check attrs and reconfigure
            $self->config_daemon($type, 'change', $qkey, $pair) or return 0;
            delete $cephh->{$qkey};
        } else {
            $self->config_daemon($type, 'add', $qkey, $quath->{$qkey}) or return 0;
        }
    }
    foreach my $ckey (keys %{$cephh}) {
        $self->config_daemon($type, 'del', $ckey, $cephh->{$ckey}) or return 0;
    }        
    return 1;
}

# Compare ceph mons with the quattor mons
sub process_mons {
    my ($self, $qmons) = @_;
    my $cmons = $self->mon_hash() or return 0;
    return $self->ceph_quattor_cmp('mon', $qmons, $cmons);
}

# Converts a host/osd hierarchy in a 'host:osd' structure
sub flatten_osds {
    my ($self, $hosds) = @_; 
    my %flat = ();
    while (my ($hostname, $host) = each(%{$hosds})) {
        my $osds = $host->{osds};
        while (my ($osdpath, $newosd) = each(%{$osds})) {
            $newosd->{host} = $hostname;
            $newosd->{fqdn} = $host->{fqdn};
            $osdpath = unescape($osdpath);
            if ($osdpath !~ m|^/|){
                $osdpath = $OSDBASE . $osdpath;
            }
            if (exists($newosd->{journal_path}) && $newosd->{journal_path} !~ m|^/|){
                $newosd->{journal_path} = $JOURNALBASE . $newosd->{journal_path};
            }
            $newosd->{osd_path} = $osdpath;
            my $osdstr = "$hostname:$osdpath" ;
            $flat{$osdstr} = $newosd;
        }
    }
    return \%flat;
}
# Compare cephs osd with the quattor osds
sub process_osds {
    my ($self, $qosds) = @_;
    my $qflosds = $self->flatten_osds($qosds);
    $self->debug(5, 'OSD lay-out', Dumper($qosds));
    my $cosds = $self->osd_hash() or return 0;
    return $self->ceph_quattor_cmp('osd', $qflosds, $cosds);
}

# Compare cephs mds with the quattor mds
sub process_mdss {
    my ($self, $qmdss) = @_;
    my $cmdss = $self->mds_hash() or return 0;
    return $self->ceph_quattor_cmp('mds', $qmdss, $cmdss);
}

# Prepare the commands to change/add/delete a monitor  
sub config_mon {
    my ($self,$action,$name,$daemonh) = @_;
    if ($action eq 'add'){
        my @command = qw(mon create);
        push (@command, $daemonh->{fqdn});
        push (@{$self->{deploy_cmds}}, [@command]);
    } elsif ($action eq 'del') {
        my @command = qw(mon destroy);
        push (@command, $name);
        push (@{$self->{man_cmds}}, [@command]);
    } elsif ($action eq 'change') { #compare config
        my $quatmon = $daemonh->[0];
        my $cephmon = $daemonh->[1];
        # checking immutable attributes
        my @monattrs = ();
        $self->check_immutables($name, \@monattrs, $quatmon, $cephmon) or return 0;
        
        if ($cephmon->{addr} =~ /^0\.0\.0\.0:0/) { #Initial (unconfigured) member
               $self->config_mon('add', $quatmon);
        }
        $self->check_state($name, $name, 'mon', $quatmon, $cephmon);
        
        my @donecmd = ('/usr/bin/ssh', $quatmon->{fqdn}, 
                       'test','-e',"/var/lib/ceph/mon/$self->{clname}-$name/done" );
        if (!$cephmon->{up} && !$self->run_command_as_ceph([@donecmd])) {
            # Node reinstalled without first destroying it
            $self->info("Monitor $name shall be reinstalled");
            return $self->config_mon('add',$name,$quatmon);
        }
    }
    else {
        $self->error("Action $action not supported!");
    }
    return 1;   
}
#does a check on unchangable attributes, returns 0 if different
sub check_immutables {
    my ($self, $name, $imm, $quat, $ceph) = @_;
    my $rc =1;
    foreach my $attr (@{$imm}) {
        if ($quat->{$attr} ne $ceph->{$attr}){
            $self->error("Attribute $attr of $name not corresponding.", 
                "Quattor: $quat->{$attr}, ",
                "Ceph: $ceph->{$attr}");
            $rc=0;
        }
    }
    return $rc;
}
# Checks and changes the state on the host
sub check_state {
    my ($self, $id, $host, $type, $quat, $ceph) = @_;
    if (($host eq $self->{hostname}) and ($quat->{up} xor $ceph->{up})){
        my @command; 
        if ($quat->{up}) {
            @command = qw(start); 
        } else {
            @command = qw(stop);
        }
        push (@command, "$type.$id");
        push (@{$self->{daemon_cmds}}, [@command]);
    }
} 
# Prepare the commands to change/add/delete an osd
sub config_osd {
    my ($self,$action,$name,$daemonh) = @_;
    if ($action eq 'add'){
        #TODO: change to 'create' ?
        $self->check_empty($daemonh->{osd_path}, $daemonh->{fqdn}) or return 0;
        $self->debug(2,"Adding osd $name");
        my $prepcmd = [qw(osd prepare)];
        my $activcmd = [qw(osd activate)];
        my $pathstring = "$daemonh->{fqdn}:$daemonh->{osd_path}";
        if ($daemonh->{journal_path}) {
            (my $journaldir = $daemonh->{journal_path}) =~ s{/journal$}{};
            my $mkdircmd = ['/usr/bin/ssh', $daemonh->{fqdn}, 'sudo', '/bin/mkdir', '-p', $journaldir];
            $self->run_command_as_ceph($mkdircmd); 
            $self->check_empty($journaldir, $daemonh->{fqdn}) or return 0; 
            $pathstring = "$pathstring:$daemonh->{journal_path}";
        }
        for my $command (($prepcmd, $activcmd)) {
            push (@$command, $pathstring);
            push (@{$self->{deploy_cmds}}, $command);
        }
    } elsif ($action eq 'del') {
        my @command = qw(osd destroy);
        push (@command, $daemonh->{name});
        push (@{$self->{man_cmds}}, [@command]);
   
    } elsif ($action eq 'change') { #compare config
        my $quatosd = $daemonh->[0];
        my $cephosd = $daemonh->[1];
        # checking immutable attributes
        my @osdattrs = ('host', 'osd_path');
        if ($quatosd->{journal_path}) {
            push(@osdattrs, 'journal_path');
        }
        $self->check_immutables($name, \@osdattrs, $quatosd, $cephosd) or return 0;
        (my $id = $cephosd->{id}) =~ s/^osd\.//;
        $self->check_state($id, $quatosd->{host}, 'osd', $quatosd, $cephosd);
        #TODO: Make it possible to bring osd 'in' or 'out' the cluster ?
    } else {
        $self->error("Action $action not supported!");
    }
    return 1;
}

# Prepare the commands to change/add/delete an mds
sub config_mds {
    my ($self,$action,$name,$daemonh) = @_;
    if ($action eq 'add'){
        my $fqdn = $daemonh->{fqdn};
        my @donecmd = ('/usr/bin/ssh', $fqdn, 'test','-e',"/var/lib/ceph/mds/$self->{clname}-$name/done" );
        my $mds_exists = $self->run_command_as_ceph([@donecmd]);
        
        if ($mds_exists) { # A down ceph mds daemon is not in map
            if ($daemonh->{up} && ($name eq $self->{hostname})) {
                my @command = ('start', "mds.$name");
                push (@{$self->{daemon_cmds}}, [@command]);
            }
        } else {
            my @command = qw(mds create);
            push (@command, $fqdn);
            push (@{$self->{deploy_cmds}}, [@command]);
        }   
    } elsif ($action eq 'del') {
        my @command = qw(mds destroy);
        push (@command, $name);
        push (@{$self->{man_cmds}}, [@command]);
    
    } elsif ($action eq 'change') {
        my $quatmds = $daemonh->[0];
        my $cephmds = $daemonh->[1];
        # Note: A down ceph mds daemon is not in map
        $self->check_state($name, $name, 'mds', $quatmds, $cephmds);
    } else {
        $self->error("Action $action not supported!");
    }
    return 1;
}


# Configure on a type basis
sub config_daemon {
    my ($self, $type,$action,$name,$daemonh) = @_;
    if ($type eq 'mon'){
        $self->config_mon($action,$name,$daemonh);
    }
    elsif ($type eq 'osd'){
        $self->config_osd($action,$name,$daemonh);
    }
    elsif ($type eq 'mds'){
        $self->config_mds($action,$name,$daemonh);
    } else {
        $self->error("No such type: $type");
    }
}

# Deploy daemons 
sub do_deploy {
    my ($self, $is_deploy) = @_;
    if ($is_deploy){ #Run only on deploy host(s)
        $self->info("Running ceph-deploy commands.");
        while (my $cmd = shift @{$self->{deploy_cmds}}) {
            $self->debug(1,@$cmd);
            $self->run_ceph_deploy_command($cmd) or return 0;
        }
    } else {
        $self->info("host is no deployhost, skipping ceph-deploy commands.");
        $self->{deploy_cmds} = [];
    }
    while (my $cmd = shift @{$self->{ceph_cmds}}) {
        $self->run_ceph_command($cmd) or return 0;
    }
    while (my $cmd = shift @{$self->{daemon_cmds}}) {
        $self->debug(1,"Daemon command:", @$cmd);
        $self->run_daemon_command($cmd) or return 0;
    }
    $self->print_cmds($self->{man_cmds});
    return 1;
}

#Initialize array buckets
sub init_commands {
    my ($self) = @_;
    $self->{deploy_cmds} = [];
    $self->{ceph_cmds} = [];
    $self->{daemon_cmds} = [];
    $self->{man_cmds} = [];
}

# Compare the configuration (and prepare commands) 
sub check_daemon_configuration {
    my ($self, $cluster) = @_;
    $self->init_commands();
    $self->process_mons($cluster->{monitors}) or return 0;
    $self->process_osds($cluster->{osdhosts}) or return 0;
    $self->process_mdss($cluster->{mdss}) or return 0;
    return 1;
}

# Does the configuration and deployment of daemons
sub do_daemon_actions {
    my ($self, $cluster, $gvalues) = @_;
    $self->{clname} = $gvalues->{clname};
    $self->{hostname} = $gvalues->{hostname};
    my $is_deploy = $gvalues->{is_deploy};
    $self->{fsid} = $cluster->{config}->{fsid};
    $self->check_daemon_configuration($cluster) or return 0;
    $self->debug(1,"deploying commands");    
    return $self->do_deploy($is_deploy);
}

1; # Required for perl module!
