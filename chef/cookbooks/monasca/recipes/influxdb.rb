#
# Cookbook Name:: monasca
# Recipe:: influxdb
#
# Copyright 2018, SUSE Linux GmbH.
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

package "influxdb"

monasca_node = node_search_with_cache("roles:monasca-server").first
monasca_monitoring_host =
  Chef::Recipe::Barclamp::Inventory.get_network_by_type(
    monasca_node, node[:monasca][:network]).address

template "/etc/influxdb/config.toml" do
  source "influxdb-config.toml.erb"
  owner node[:monasca][:influxdb][:user]
  group node[:monasca][:influxdb][:group]
  mode "0640"
  variables(
    bind_address: monasca_monitoring_host
  )
  notifies :restart, "service[influxdb]"
end

service "influxdb" do
  supports status: true, restart: true, start: true, stop: true
  action [:enable, :start]
end
