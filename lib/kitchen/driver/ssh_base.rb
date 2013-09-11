# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'socket'

module Kitchen

  module Driver

    # Base class for a driver that uses SSH to communication with an instance.
    # A subclass must implement the following methods:
    # * #create(state)
    # * #destroy(state)
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class SSHBase < Base

      default_config :sudo, true
      default_config :port, 22

      def create(state)
        raise ClientError, "#{self.class}#create must be implemented"
      end

      def converge(state)
        provisioner = new_provisioner

        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(provisioner.install_command, conn)
          run_remote(provisioner.init_command, conn)
          transfer_path(provisioner.create_sandbox, provisioner.home_path, conn)
          run_remote(provisioner.prepare_command, conn)
          run_remote(provisioner.run_command, conn)
        end
      ensure
        provisioner && provisioner.cleanup_sandbox
      end

      def setup(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(busser_setup_cmd, conn)
        end
      end

      def verify(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(busser_sync_cmd, conn)
          run_remote(busser_run_cmd, conn)
        end
      end

      def destroy(state)
        raise ClientError, "#{self.class}#destroy must be implemented"
      end

      def login_command(state)
        SSH.new(*build_ssh_args(state)).login_command
      end

      def ssh(ssh_args, command)
        Kitchen::SSH.new(*ssh_args) do |conn|
          run_remote(command, conn)
        end
      end

      protected

      def new_provisioner
        combined = config.dup
        combined[:log_level] = Util.from_logger_level(logger.level)
        Provisioner.for_plugin(combined[:provisioner], instance, combined)
      end

      def build_ssh_args(state)
        combined = config.to_hash.merge(state)

        opts = Hash.new
        opts[:user_known_hosts_file] = "/dev/null"
        opts[:paranoid] = false
        opts[:password] = combined[:password] if combined[:password]
        opts[:forward_agent] = combined[:forward_agent] if combined.key? :forward_agent
        opts[:port] = combined[:port] if combined[:port]
        opts[:keys] = Array(combined[:ssh_key]) if combined[:ssh_key]
        opts[:logger] = logger

        [combined[:hostname], combined[:username], opts]
      end

      def inject_real_hostname_into_proxy_configs
        hostname = Socket.gethostbyname(Socket.gethostname).first

        if config[:http_proxy]
          config[:http_proxy] = config[:http_proxy].sub('HOST_MACHINE', hostname)
        end
        if config[:https_proxy]
          config[:https_proxy] = config[:https_proxy].sub('HOST_MACHINE', hostname)
        end
      end

      def env_cmd(cmd)
        if (config[:http_proxy] || config[:https_proxy])
          # TODO: don't mutate, return copy?
          inject_real_hostname_into_proxy_configs()

          http_proxy_working = true
          https_proxy_working = true
          if config[:proxy_health_checking]
            puts "proxy_health_checking enabled, testing..."
            # TODO: make this use net:http. don't know if curl is present.
            http_test_command = "bash -c 'http_proxy=#{config[:http_proxy]} curl http://www.google.com > /dev/null 2>&1'"
            https_test_command = "bash -c 'https_proxy=#{config[:https_proxy]} curl https://www.google.com > /dev/null 2>&1'"
            if system(http_test_command)
              puts "http_proxy configured and working. enabling."
            else
              http_proxy_working = false
              puts "http_proxy configured, but not reachable! disabling."
            end
            if system(https_test_command)
              puts "https_proxy configured and working. enabling."
            else
              https_proxy_working = false
              puts "https_proxy configured, but not reachable! disabling."
            end
          end
        end

        env = "env"
        env << " http_proxy=#{config[:http_proxy]}"   if (config[:http_proxy] && http_proxy_working)
        env << " https_proxy=#{config[:https_proxy]}" if (config[:https_proxy] && https_proxy_working)

        additional_paths = []
        additional_paths << config[:ruby_binpath] if config[:ruby_binpath]
        additional_paths << config[:path] if config[:path]
        env << " PATH=$PATH:#{additional_paths.join(':')}" if additional_paths.any?

        env == "env" ? cmd : "#{env} #{cmd}"
      end

      def run_remote(command, connection)
        return if command.nil?

        connection.exec(env_cmd(command))
      rescue SSHFailed, Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      def transfer_path(local, remote, connection)
        return if local.nil?

        connection.upload_path!(local, remote)
      rescue SSHFailed, Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      def wait_for_sshd(hostname, username = nil, options = {})
        SSH.new(hostname, username, { :logger => logger }.merge(options)).wait
      end
    end
  end
end
