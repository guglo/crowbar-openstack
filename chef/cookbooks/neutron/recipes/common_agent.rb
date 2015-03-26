# Copyright 2013 Dell, Inc.
# Copyright 2014-2015 SUSE Linux GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

neutron = nil
if node.attribute?(:cookbook) and node[:cookbook] == "nova"
  neutrons = search(:node, "roles:neutron-server AND roles:neutron-config-#{node[:nova][:neutron_instance]}")
  neutron = neutrons.first || raise("Neutron instance '#{node[:nova][:neutron_instance]}' for nova not found")
else
  neutron = node
end

# Disable rp_filter
ruby_block "edit /etc/sysctl.conf for rp_filter" do
  block do
    rc = Chef::Util::FileEdit.new("/etc/sysctl.conf")
    rc.search_file_replace_line(/^net.ipv4.conf.all.rp_filter/, 'net.ipv4.conf.all.rp_filter = 0')
    rc.write_file
  end
  only_if { node[:platform] == "suse" }
end

directory "create /etc/sysctl.d for disable-rp_filter" do
  path "/etc/sysctl.d"
  mode "755"
end

disable_rp_filter_file = "/etc/sysctl.d/50-neutron-disable-rp_filter.conf"
cookbook_file disable_rp_filter_file do
  source "sysctl-disable-rp_filter.conf"
  mode "0644"
end

bash "reload disable-rp_filter-sysctl" do
  code "/sbin/sysctl -e -q -p #{disable_rp_filter_file}"
  action :nothing
  subscribes :run, resources(:cookbook_file=> disable_rp_filter_file), :delayed
end

if neutron[:neutron][:networking_plugin] == "ml2"
  ml2_mech_drivers = neutron[:neutron][:ml2_mechanism_drivers]
  case
  when ml2_mech_drivers.include?("openvswitch")
    neutron_agent = neutron[:neutron][:platform][:ovs_agent_name]
    neutron_agent_pkg = neutron[:neutron][:platform][:ovs_agent_pkg]
    agent_config_path = "/etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini"
  when ml2_mech_drivers.include?("linuxbridge")
    neutron_agent = neutron[:neutron][:platform][:lb_agent_name]
    neutron_agent_pkg = neutron[:neutron][:platform][:lb_agent_pkg]
    agent_config_path = "/etc/neutron/plugins/linuxbridge/linuxbridge_conf.ini"
  end

  # agent package/git installation
  unless neutron[:neutron][:use_gitrepo]
    package neutron_agent_pkg do
      action :install
    end
  else
    neutron_path = "/opt/neutron"
    venv_path = neutron[:neutron][:use_virtualenv] ? "#{neutron_path}/.venv" : nil

    neutron_agent = "neutron-openvswitch-agent"
    pfs_and_install_deps "neutron" do
      cookbook "neutron"
      cnode neutron
      virtualenv venv_path
      path neutron_path
      wrap_bins [ "neutron", "neutron-rootwrap" ]
    end

    create_user_and_dirs("neutron")

    link_service neutron_agent do
      virtualenv venv_path
      bin_name "neutron-openvswitch-agent --config-file #{agent_config_path} --config-dir /etc/neutron/"
    end

    execute "neutron_cp_policy.json" do
      command "cp /opt/neutron/etc/policy.json /etc/neutron/"
      creates "/etc/neutron/policy.json"
    end
    execute "neutron_cp_plugins" do
      command "cp -r /opt/neutron/etc/neutron/plugins /etc/neutron/plugins"
      creates "/etc/neutron/plugins"
    end
    execute "neutron_cp_rootwrap" do
      command "cp -r /opt/neutron/etc/neutron/rootwrap.d /etc/neutron/rootwrap.d"
      creates "/etc/neutron/rootwrap.d"
    end
    cookbook_file "/etc/neutron/rootwrap.conf" do
      cookbook "neutron"
      source "neutron-rootwrap.conf"
      mode 00644
      owner "root"
      group node[:neutron][:platform][:group]
    end
  end

  ml2_type_drivers = neutron[:neutron][:ml2_type_drivers]

  case
  when ml2_mech_drivers.include?("openvswitch")
    directory "/etc/neutron/plugins/openvswitch/" do
      mode 00755
      owner "root"
      group neutron[:neutron][:platform][:group]
      action :create
      recursive true
      not_if { node[:platform] == "suse" }
    end

    template agent_config_path do
      cookbook "neutron"
      source "ovs_neutron_plugin.ini.erb"
      owner "root"
      group neutron[:neutron][:platform][:group]
      mode "0640"
      variables(
        :ml2_type_drivers => ml2_type_drivers,
        :tunnel_types => ml2_type_drivers.select { |t| ["vxlan", "gre"].include?(t) },
        :use_l2pop => neutron[:neutron][:use_l2pop] && (ml2_type_drivers.include?("gre") || ml2_type_drivers.include?("vxlan")),
        :dvr_enabled => neutron[:neutron][:use_dvr]
      )
    end
  when ml2_mech_drivers.include?("linuxbridge")
    directory "/etc/neutron/plugins/linuxbridge/" do
      mode 00755
      owner "root"
      group neutron[:neutron][:platform][:group]
      action :create
      recursive true
      not_if { node[:platform] == "suse" }
    end

    template agent_config_path do
      cookbook "neutron"
      source "linuxbridge_conf.ini.erb"
      owner "root"
      group neutron[:neutron][:platform][:group]
      mode "0640"
      variables(
        :physnet => (node[:crowbar_wall][:network][:nets][:nova_fixed].first rescue nil),
        :ml2_type_drivers => ml2_type_drivers,
        :vxlan_mcast_group => neutron[:neutron][:vxlan][:multicast_group],
        :use_l2pop => neutron[:neutron][:use_l2pop] && ml2_type_drivers.include?("vxlan")
      )
    end
  end
end


# openvswitch installation and configuration
if neutron[:neutron][:networking_plugin] == 'vmware' or
  (neutron[:neutron][:networking_plugin] == 'ml2' and
   neutron[:neutron][:ml2_mechanism_drivers].include?("openvswitch"))
  if node.platform == "ubuntu"
    # If we expect to install the openvswitch module via DKMS, but the module
    # does not exist, rmmod the openvswitch module before continuing.
    if node[:neutron][:platform][:ovs_pkgs].any?{|e|e == "openvswitch-datapath-dkms"} &&
        !File.exists?("/lib/modules/#{%x{uname -r}.strip}/updates/dkms/openvswitch.ko") &&
        File.directory?("/sys/module/openvswitch")
      if IO.read("/sys/module/openvswitch/refcnt").strip != "0"
        Chef::Log.error("Kernel openvswitch module already loaded and in use! Please reboot me!")
      else
        bash "Unload non-DKMS openvswitch module" do
          code "rmmod openvswitch"
        end
      end
    end
  end

  node[:neutron][:platform][:ovs_pkgs].each { |p| package p }

  bash "Load openvswitch module" do
    code node[:neutron][:platform][:ovs_modprobe]
    not_if do ::File.directory?("/sys/module/openvswitch") end
  end

  if %w(redhat centos).include?(node.platform)
    openvswitch_service = "openvswitch"
  else
    openvswitch_service = "openvswitch-switch"
  end

  service "openvswitch_service" do
    service_name openvswitch_service
    supports :status => true, :restart => true
    action [ :start, :enable ]
  end
end

# openvswitch configuration specific to ML2
if neutron[:neutron][:networking_plugin] == 'ml2' and
   neutron[:neutron][:ml2_mechanism_drivers].include?("openvswitch")

  unless %w(debian ubuntu).include? node.platform
    # Note: this must not be started! This service only makes sense on boot.
    service "neutron-ovs-cleanup" do
      service_name "openstack-neutron-ovs-cleanup" if %w(suse).include?(node.platform)
      action [ :enable ]
    end
  else
    # Arrange for neutron-ovs-cleanup to be run on bootup of compute nodes only
    unless neutron.name == node.name
      cookbook_file "/etc/init.d/neutron-ovs-cleanup" do
        source "neutron-ovs-cleanup"
        mode 00755
      end
      link "/etc/rc2.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
      link "/etc/rc3.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
      link "/etc/rc4.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
      link "/etc/rc5.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
    end
  end

  # This only includes the IP addresses allocated to the node by crowbar. It
  # does not include e.g. virtual IP addresses allocated to a cluster. Which is
  # important as we need to filter those out from being added to the
  # ovs-usurp-config init script that is being created below.
  my_addresses = node.all_addresses

  # Create the bridges Neutron needs.
  # Usurp config as needed.
  [ [ "nova_fixed", "fixed" ],
    [ "public", "public"] ].each do |net|
    bound_if = (node[:crowbar_wall][:network][:nets][net[0]].last rescue nil)
    next unless bound_if
    name = "br-#{net[1]}"
    execute "Neutron: create #{name}" do
      command "ovs-vsctl add-br #{name}; ip link set #{name} up"
      not_if "ovs-vsctl list-br |grep -q #{name}"
    end
    execute "Neutron: add #{bound_if} to #{name}" do
      command "ovs-vsctl del-port #{name} #{bound_if} ; ovs-vsctl add-port #{name} #{bound_if}"
      not_if "ovs-dpctl show system@#{name} | grep -q #{bound_if}"
    end
    ruby_block "Have #{name} usurp config from #{bound_if}" do
      block do
        target = ::Nic.new(name)
        res = target.usurp(bound_if)
        Chef::Log.info("#{name} usurped #{res[0].join(", ")} addresses from #{bound_if}") unless res[0].empty?
        Chef::Log.info("#{name} usurped #{res[1].join(", ")} routes from #{bound_if}") unless res[1].empty?
      end
    end
    source = ::Nic.new(bound_if)
    # filter out cluster VIPs that a currently assigned to the interface
    addresses = source.addresses.select { |address| my_addresses.include? address }
    routes = source.routes
    template "/etc/init.d/ovs-usurp-config-#{name}" do
      source "ovs-usurp-config.erb"
      owner "root"
      group "root"
      mode "0755"
      variables(
        :source => bound_if,
        :dest => name,
        :addresses => addresses,
        :routes => routes
      )
      # After the ruby_block "Have #{name} usurp config from #{bound_if}" was
      # executed for the first time, the physical interface (eth) will not have
      # any addresses or routes assigned anymore. So we should not recreate the
      # init script in that case. Neither should it be removed.
      not_if { addresses.empty? and routes.empty? }
    end
    service "ovs-usurp-config-#{name}" do
      # Don't start it here. It only needs to be executed during boot.
      action [:nothing]
      subscribes :enable, resources("template[/etc/init.d/ovs-usurp-config-#{name}]")
    end
  end
else
  # Cleanup the ovs-usurp init scripts if we're not using openvswitch anymore.
  # Note: As moving between network plugins is currently not supported by this
  #       cookbook this code is mostly just sitting here and waiting for the
  #       plugin switching support to be implemented.
  [ "br-public", "br-fixed" ].each do |name|
    service "ovs-usurp-config-#{name}" do
      # FIXME: Don't stop it here until we handle the shutdown of openvswitch
      #        and the neutron-ovs-agent correctly. Otherwise we might be cut
      #        off of the network immediately.
      action [:disable]
      only_if { ::File.exists?("/etc/init.d/ovs-usurp-config-#{name}") }
    end
    file "/etc/init.d/ovs-usurp-config-#{name}" do
      action :delete
    end
  end
end

# ML2 configuration: L2 agent and L3 agent
if neutron[:neutron][:networking_plugin] == "ml2"
  include_recipe "neutron::common_config"

  neutron_network_ha = node.roles.include?("neutron-network") && neutron[:neutron][:ha][:network][:enabled]

  service neutron_agent do
    supports :status => true, :restart => true
    action [:enable, :start]
    subscribes :restart, resources("template[#{agent_config_path}]")
    subscribes :restart, resources("template[/etc/neutron/neutron.conf]")
    provider Chef::Provider::CrowbarPacemakerService if neutron_network_ha
  end

  if neutron[:neutron][:use_dvr] || node.roles.include?("neutron-network")
    unless neutron[:neutron][:use_gitrepo]
      package node[:neutron][:platform][:l3_agent_pkg]
    else
      link_service "neutron-l3-agent" do
        virtualenv venv_path
        bin_name "neutron-l3-agent --config-dir /etc/neutron/"
      end
    end

    ml2_mech_drivers = neutron[:neutron][:ml2_mechanism_drivers]
    case
    when ml2_mech_drivers.include?("openvswitch")
      interface_driver = "neutron.agent.linux.interface.OVSInterfaceDriver"
      external_network_bridge = "br-public"
    when ml2_mech_drivers.include?("linuxbridge")
      interface_driver = "neutron.agent.linux.interface.BridgeInterfaceDriver"
      external_network_bridge = ""
    end

    template "/etc/neutron/l3_agent.ini" do
      source "l3_agent.ini.erb"
      owner "root"
      group node[:neutron][:platform][:group]
      mode "0640"
      variables(
        :debug => neutron[:neutron][:debug],
        :interface_driver => interface_driver,
        :use_namespaces => "True",
        :handle_internal_only_routers => "True",
        :metadata_port => 9697,
        :send_arp_for_ha => 3,
        :periodic_interval => 40,
        :periodic_fuzzy_delay => 5,
        :external_network_bridge => external_network_bridge,
        :dvr_enabled => neutron[:neutron][:use_dvr],
        :dvr_mode => node.roles.include?("neutron-network") ? "dvr_snat" : "dvr"
      )
    end

    service node[:neutron][:platform][:l3_agent_name] do
      service_name "neutron-l3-agent" if neutron[:neutron][:use_gitrepo]
      supports :status => true, :restart => true
      action [:enable, :start]
      subscribes :restart, resources("template[/etc/neutron/neutron.conf]")
      subscribes :restart, resources("template[/etc/neutron/l3_agent.ini]")
      provider Chef::Provider::CrowbarPacemakerService if neutron_network_ha
    end
  end
end

if neutron[:neutron][:networking_plugin] == "vmware"
  include_recipe "neutron::vmware_support"
  # We don't need anything more installed or configured on
  # compute nodes except openvswitch packages with stt.
  # For NSX plugin no neutron packages are needed.
end
