# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'solid_waffle'
require 'bolt_spec/run'
require 'open3'
require 'pdk'

def run_local_command(command)
  stdout, stderr, status = Open3.capture3(command)
  error_message = "Attempted to run\ncommand:'#{command}'\nstdout:#{stdout}\nstderr:#{stderr}"
  raise error_message unless status.to_i.zero?

  stdout
end

def install_ssh_components(platform, container)
  case platform
  when %r{debian}, %r{ubuntu}
    run_local_command("docker exec #{container} apt-get update")
    run_local_command("docker exec #{container} apt-get install -y openssh-server openssh-client")
  when %r{cumulus}
    run_local_command("docker exec #{container} apt-get update")
    run_local_command("docker exec #{container} apt-get install -y openssh-server openssh-client")
  when %r{fedora-(2[2-9])}
    run_local_command("docker exec #{container} dnf clean all")
    run_local_command("docker exec #{container} dnf install -y sudo openssh-server openssh-clients")
    run_local_command("docker exec #{container} ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key")
    run_local_command("docker exec #{container} ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key")
  when %r{centos}, %r{^el-}, %r{eos}, %r{fedora}, %r{oracle}, %r{redhat}, %r{scientific}
    run_local_command("docker exec #{container} yum clean all")
    run_local_command("docker exec #{container} yum install -y sudo openssh-server openssh-clients")
    run_local_command("docker exec #{container} ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''")
    run_local_command("docker exec #{container} ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''")
  when %r{opensuse}, %r{sles}
    run_local_command("docker exec #{container} zypper -n in openssh")
    run_local_command("docker exec #{container} ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key")
    run_local_command("docker exec #{container} ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key")
    run_local_command("docker exec #{container} sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config")
  when %r{archlinux}
    run_local_command("docker exec #{container} pacman --noconfirm -Sy archlinux-keyring")
    run_local_command("docker exec #{container} pacman --noconfirm -Syu")
    run_local_command("docker exec #{container} pacman -S --noconfirm openssh")
    run_local_command("docker exec #{container} ssh-keygen -A")
    run_local_command("docker exec #{container} sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config")
    run_local_command("docker exec #{container} systemctl enable sshd")
  else
    raise "platform #{platform} not yet supported on docker"
  end

  # Make sshd directory, set root password
  run_local_command("docker exec #{container} mkdir -p /var/run/sshd")
  run_local_command("docker exec #{container} bash -c 'echo root:root | /usr/sbin/chpasswd'")
end

def fix_ssh(platform, container)
  run_local_command("docker exec #{container} sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config")
  run_local_command("docker exec #{container} sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config")
  run_local_command("docker exec #{container} sed -ri 's/^#?UseDNS .*/UseDNS no/' /etc/ssh/sshd_config")
  run_local_command("docker exec #{container} sed -e '/HostKey.*ssh_host_e.*_key/ s/^#*/#/' -ri /etc/ssh/sshd_config")
  case platform
  when %r{debian}, %r{ubuntu}
    run_local_command("docker exec #{container} service ssh restart")
  when %r{centos}, %r{^el-}, %r{eos}, %r{fedora}, %r{oracle}, %r{redhat}, %r{scientific}
    if container !~ %r{7}
      run_local_command("docker exec #{container} service sshd restart")
    else
      run_local_command("docker exec -d #{container} /usr/sbin/sshd -D")
    end
  else
    raise "platform #{platform} not yet supported on docker"
  end
end

namespace :waffle do
  desc "provision machines - vmpooler eg 'bundle exec rake 'provision[ubuntu-1604-x86_64]'"
  task :provision, [:provisioner, :platform] do |_task, args|
    Rake::Task['spec_prep'].invoke
    if args[:provisioner] == 'vmpooler'
      # vmpooler
      config_data = { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }
      raise "waffle_provision was not found in #{config_data['modulepath']}, please amend the .fixtures.yml file" unless File.directory?(File.join(config_data['modulepath'], 'waffle_provision'))

      params = { 'action' => 'provision', 'platform' => args[:platform], 'inventory' => Dir.pwd }
      result = run_task('waffle_provision::vmpooler', 'localhost', params, config: config_data, inventory: nil)
      puts result
    elsif args[:provisioner] == 'docker'
      include SolidWaffle
      inventory_hash = if File.file?('inventory.yaml')
                         inventory_hash_from_inventory_file
                       else
                         { 'groups' => [{ 'name' => 'ssh_nodes', 'nodes' => [] }, { 'name' => 'winrm_nodes', 'nodes' => [] }] }
                       end
      warn '!!! Using private port forwarding!!!'
      platform, version = args[:platform].split(':')
      front_facing_port = 2222
      platform = platform.sub(%r{/}, '_')
      full_container_name = "#{platform}_#{version}-#{front_facing_port}"
      (front_facing_port..2230).each do |i|
        front_facing_port = i
        full_container_name = "#{platform}_#{version}-#{front_facing_port}"
        _stdout, stderr, _status = Open3.capture3("docker port #{full_container_name}")
        break unless (stderr =~ %r{No such container}i).nil?
        raise 'All front facing ports are in use.' if front_facing_port == 2230
      end
      puts "Provisioning #{full_container_name}"
      creation_command = "docker run -d -it -p #{front_facing_port}:22 --name #{full_container_name} #{args[:platform]}"
      run_local_command(creation_command)
      install_ssh_components(platform, full_container_name)
      fix_ssh(platform, full_container_name)
      hostname = 'localhost'
      node = { 'name' => "#{hostname}:#{front_facing_port}",
               'config' => { 'transport' => 'ssh',
                             'ssh' => { 'user' => 'root', 'password' => 'root', 'port' => front_facing_port, 'host-key-check' => false } },
               'facts' => { 'provisioner' => 'docker', 'container_name' => full_container_name } }
      group_name = 'ssh_nodes'
      add_node_to_group(inventory_hash, node, group_name)
      File.open('inventory.yaml', 'w') { |f| f.write inventory_hash.to_yaml }
    else
      raise "Unknown provisioner '#{args[:provisioner]}', try docker/vmpooler"
    end
  end

  desc 'install puppet agent, [:hostname, :collection]'
  task :install_agent, [:hostname, :collection] do |_task, args|
    puts 'install_agent'
    include BoltSpec::Run
    inventory_hash = inventory_hash_from_inventory_file
    targets = find_targets(inventory_hash, args[:hostname])
    Rake::Task['spec_prep'].invoke
    config_data = { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }
    params = if args[:collection].nil?
               nil
             else
               "collection=#{args[:collection]}"
             end
    raise "puppet_agent was not found in #{config_data['modulepath']}, please amend the .fixtures.yml file" unless File.directory?(File.join(config_data['modulepath'], 'puppet_agent'))

    result = run_task('puppet_agent::install', targets, params, config: config_data, inventory: inventory_hash)
    puts result
    # fix the path on ssh_nodes
    run_command('sed -i \'s!^\(\s*PATH=\)[^"]*"!\1"/opt/puppetlabs/puppet/bin:!\' /etc/environment', 'ssh_nodes', config: nil, inventory: inventory_hash) unless inventory_hash['groups'].select { |group| group['name'] == 'ssh_nodes' }.size.zero?
  end

  desc 'install_module - build and install module'
  task :install_module, [:target_node_name] do |_task, args|
    include BoltSpec::Run
    # old cli_way
    # pdk_build_command = 'bundle exec pdk build  --force'
    # stdout, stderr, _status = Open3.capture3(pdk_build_command)
    # raise "Failed to run 'pdk_build_command',#{stdout} and #{stderr}" if (stderr =~ %r{completed successfully}).nil?
    require 'pdk/module/build'
    opts = {}
    opts[:force] = true
    builder = PDK::Module::Build.new(opts)
    module_tar = builder.build
    puts 'Built'

    inventory_hash = inventory_hash_from_inventory_file
    target_nodes = find_targets(inventory_hash, args[:target_node_name])
    # module_tar = Dir.glob('pkg/*.tar.gz').max_by { |f| File.mtime(f) }
    raise "Unable to find package in 'pkg/*.tar.gz'" if module_tar.nil?

    target_string = if args[:target_node_name].nil?
                      'all'
                    else
                      args[:target_node_name]
                    end
    run_local_command("bundle exec bolt file upload #{module_tar} /tmp/#{File.basename(module_tar)} --nodes #{target_string} --inventoryfile inventory.yaml")
    install_module_command = "puppet module install /tmp/#{File.basename(module_tar)}"
    result = run_command(install_module_command, target_nodes, config: nil, inventory: inventory_hash)
    if result.is_a?(Array)
      result.each do |node|
        puts "#{node['node']} failed #{node['result']}" if node['status'] != 'success'
      end
    else
      raise "Failed trying to run '#{install_module_command}' against inventory."
    end
    puts 'Installed'
  end

  desc 'tear-down - decommission machines'
  task :tear_down, [:target] do |_task, args|
    Rake::Task['spec_prep'].invoke
    config_data = { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }
    raise "waffle_provision was not found in #{config_data['modulepath']}, please amend the .fixtures.yml file" unless File.directory?(File.join(config_data['modulepath'], 'waffle_provision'))

    inventory_hash = inventory_hash_from_inventory_file
    targets = find_targets(inventory_hash, args[:target])
    targets.each do |node_name|
      # how do we know what provisioner to use
      node_facts = facts_from_node(inventory_hash, node_name)
      case node_facts['provisioner']
      when %r{vmpooler}
        params = { 'action' => 'tear_down', 'node_name' => node_name, 'inventory' => Dir.pwd }
        result = run_task('waffle_provision::vmpooler', 'localhost', params, config: config_data, inventory: nil)
        puts result
      when %r{docker}
        remove_docker = "docker rm -f #{node_facts['container_name']}"
        run_local_command(remove_docker)
        remove_node(inventory_hash, node_name)
        puts "Removed #{node_name}"
        File.open('inventory.yaml', 'w') { |f| f.write inventory_hash.to_yaml }
      end
    end
  end
end

if File.file?('inventory.yaml')
  namespace :acceptance do
    include SolidWaffle
    inventory_hash = inventory_hash_from_inventory_file
    hosts = find_targets(inventory_hash, nil)
    desc 'Run serverspec against all hosts'
    task all: hosts
    hosts.each do |host|
      desc "Run serverspec against #{host}"
      RSpec::Core::RakeTask.new(host.to_sym) do |t|
        t.pattern = 'spec/acceptance/**{,/*/**}/*_spec.rb'
        ENV['TARGET_HOST'] = host
      end
    end
  end
end
