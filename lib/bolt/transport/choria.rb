# frozen_string_literal: true

require 'json'
require 'shellwords'
require 'fileutils'
require 'base64'
require 'securerandom'
require 'mcollective'
require_relative '../../bolt/transport/base'

module Bolt
  module Transport
    class Choria < Base
      # Path to the directory containing bundled MCollective agent DDL files.
      # These are required by the MCollective RPC client for input validation
      # and timeout configuration for the shell and rpcutil agents.
      DDL_DIR = File.expand_path('choria', __dir__).freeze

      # Maximum size of file content to send in a single base64-encoded chunk
      # through the Choria shell agent. 256KB encoded becomes ~350KB base64.
      UPLOAD_CHUNK_SIZE = 262_144

      # Directories to skip when recursively uploading.
      DOT_DIRS = ['.', '..'].freeze

      def initialize
        super
        @rpc_mutex = Mutex.new
        @config_loaded = false
        @rpc_clients = {}
      end

      def provided_features
        ['shell']
      end

      def run_command(target, command, options = {}, position = [])
        with_choria_env(target, options[:env_vars]) do |env_prefix|
          full_command = "#{env_prefix}#{command}"
          result = choria_shell_run(target, full_command)
          Bolt::Result.for_command(target, result, 'command', command, position)
        end
      end

      def run_script(target, script, arguments, options = {}, position = [])
        # Unpack any Sensitive data
        arguments = unwrap_sensitive_args(arguments)

        with_remote_tmpdir(target) do |dir|
          basename = File.basename(script)
          remote_path = File.join(dir, basename)

          upload_file_to_target(target, script, remote_path)
          choria_shell_run(target, "chmod u+x #{Shellwords.shellescape(remote_path)}")

          interpreter = select_interpreter(script, target.transport_config['interpreters'])

          exec_args = if interpreter
                        "#{Array(interpreter).shelljoin} #{Shellwords.shellescape(remote_path)} #{arguments.shelljoin}"
                      else
                        "#{Shellwords.shellescape(remote_path)} #{arguments.shelljoin}"
                      end

          with_choria_env(target, options[:env_vars]) do |env_prefix|
            result = choria_shell_run(target, "#{env_prefix}#{exec_args}")
            Bolt::Result.for_command(target, result, 'script', script, position)
          end
        end
      end

      def run_task(target, task, arguments, _options = {}, position = [])
        implementation = select_implementation(target, task)
        executable = implementation['path']
        input_method = implementation['input_method']
        extra_files = implementation['files']

        # Unpack any Sensitive data
        arguments = unwrap_sensitive_args(arguments)

        with_remote_tmpdir(target) do |dir|
          if extra_files.empty?
            task_dir = dir
          else
            arguments['_installdir'] = dir
            task_dir = File.join(dir, task.tasks_dir)

            # Create needed directories and upload extra files
            dirs_to_create = [task.tasks_dir] + extra_files.map { |f| File.dirname(f['name']) }
            dirs_to_create.uniq.each do |d|
              choria_shell_run(target, "mkdir -p #{Shellwords.shellescape(File.join(dir, d))}")
            end

            extra_files.each do |file|
              upload_file_to_target(target, file['path'], File.join(dir, file['name']))
            end
          end

          remote_task_path = File.join(task_dir, File.basename(executable))
          upload_file_to_target(target, executable, remote_task_path)
          choria_shell_run(target, "chmod u+x #{Shellwords.shellescape(remote_task_path)}")

          stdin = nil
          env_vars = {}

          if Bolt::Task::STDIN_METHODS.include?(input_method)
            stdin = JSON.dump(arguments)
          end

          if Bolt::Task::ENVIRONMENT_METHODS.include?(input_method)
            arguments.each { |k, v| env_vars["PT_#{k}"] = v.to_s }
          end

          interpreter = select_interpreter(executable, target.transport_config['interpreters'])
          task_command = if interpreter
                           "#{Array(interpreter).shelljoin} #{Shellwords.shellescape(remote_task_path)}"
                         else
                           Shellwords.shellescape(remote_task_path)
                         end

          env_prefix = build_env_prefix(env_vars)

          full_command = if stdin
                           escaped_stdin = Shellwords.shellescape(stdin)
                           "#{env_prefix}echo #{escaped_stdin} | #{task_command}"
                         else
                           "#{env_prefix}#{task_command}"
                         end

          result = choria_shell_run(target, full_command)

          Bolt::Result.for_task(
            target,
            result['stdout'] || '',
            result['stderr'] || '',
            result['exit_code'],
            task.name,
            position
          )
        end
      end

      def upload(target, source, destination, _options = {})
        upload_file_to_target(target, source, destination)
        Bolt::Result.for_upload(target, source, destination)
      end

      def download(target, source, destination, _options = {})
        download_path = File.join(destination, File.basename(source))
        download_file_from_target(target, source, download_path)
        Bolt::Result.for_download(target, source, destination, download_path)
      end

      def connected?(target)
        result = execute_choria_rpc(target, 'rpcutil', 'ping')
        result[:success]
      rescue StandardError
        false
      end

      private

      # Builds an environment variable prefix string for shell commands.
      def build_env_prefix(env_vars)
        return '' if env_vars.nil? || env_vars.empty?

        env_str = env_vars.map { |k, v| "#{k}=#{Shellwords.shellescape(v)}" }.join(' ')
        "/usr/bin/env #{env_str} "
      end

      # Wraps a block with an environment variable prefix.
      def with_choria_env(_target, env_vars)
        yield build_env_prefix(env_vars)
      end

      # Creates a temporary directory on the remote target and yields the path.
      # Cleans up afterward if the cleanup option is enabled.
      def with_remote_tmpdir(target)
        tmpdir = target.transport_config.fetch('tmpdir', '/tmp')
        dir_name = "bolt-#{SecureRandom.uuid}"
        remote_dir = File.join(tmpdir, dir_name)

        result = choria_shell_run(target, "mkdir -m 700 -p #{Shellwords.shellescape(remote_dir)}")
        unless result['exit_code'].zero?
          raise Bolt::Node::FileError.new(
            "Could not create tmpdir on #{target.safe_name}: #{result['stderr']}",
            'TMPDIR_ERROR'
          )
        end

        yield remote_dir
      ensure
        if target.transport_config.fetch('cleanup', true)
          choria_shell_run(target, "rm -rf #{Shellwords.shellescape(remote_dir)}")
        end
      end

      # Uploads a local file to a target via the Choria shell agent using base64 encoding.
      # Handles both files and directories.
      def upload_file_to_target(target, source, destination)
        if File.directory?(source)
          upload_directory_to_target(target, source, destination)
        else
          upload_single_file(target, source, destination)
        end
      end

      # Uploads a directory recursively to the target.
      def upload_directory_to_target(target, source, destination)
        choria_shell_run(target, "mkdir -p #{Shellwords.shellescape(destination)}")

        Dir.glob(File.join(source, '**', '*'), File::FNM_DOTMATCH).each do |local_path|
          next if DOT_DIRS.include?(File.basename(local_path))

          relative = local_path.sub("#{source}/", '')
          remote_path = File.join(destination, relative)

          if File.directory?(local_path)
            choria_shell_run(target, "mkdir -p #{Shellwords.shellescape(remote_path)}")
          else
            upload_single_file(target, local_path, remote_path)
          end
        end
      end

      # Uploads a single file to the target by base64 encoding its content and
      # sending it through the Choria shell agent in chunks.
      def upload_single_file(target, source, destination)
        @logger.trace { "Uploading #{source} to #{destination} on #{target.safe_name}" }

        content = File.binread(source)

        if content.empty?
          result = choria_shell_run(target, "touch #{Shellwords.shellescape(destination)}")
          unless result['exit_code'].zero?
            raise Bolt::Node::FileError.new(
              "Error uploading file to #{target.safe_name}: #{result['stderr']}",
              'WRITE_ERROR'
            )
          end
          return
        end

        # Split file into chunks for transfer
        offset = 0
        first_chunk = true
        while offset < content.length
          chunk = content.byteslice(offset, UPLOAD_CHUNK_SIZE)
          encoded = Base64.strict_encode64(chunk)
          operator = first_chunk ? '>' : '>>'

          result = choria_shell_run(
            target,
            "echo #{Shellwords.shellescape(encoded)} | base64 -d #{operator} #{Shellwords.shellescape(destination)}"
          )

          unless result['exit_code'].zero?
            raise Bolt::Node::FileError.new(
              "Error uploading file to #{target.safe_name}: #{result['stderr']}",
              'WRITE_ERROR'
            )
          end

          offset += UPLOAD_CHUNK_SIZE
          first_chunk = false
        end

        # Preserve file permissions
        if File.executable?(source)
          choria_shell_run(target, "chmod u+x #{Shellwords.shellescape(destination)}")
        end
      end

      # Downloads a file from the target by reading it via the Choria shell agent.
      def download_file_from_target(target, source, destination)
        @logger.trace { "Downloading #{source} from #{target.safe_name} to #{destination}" }

        # Check if source is a directory
        is_dir_result = choria_shell_run(target, "test -d #{Shellwords.shellescape(source)} && echo dir || echo file")

        if is_dir_result['stdout'].strip == 'dir'
          download_directory_from_target(target, source, destination)
        else
          download_single_file(target, source, destination)
        end
      end

      # Downloads a directory from the target recursively.
      def download_directory_from_target(target, source, destination)
        FileUtils.mkdir_p(destination)

        # List all files in the directory
        list_result = choria_shell_run(target, "find #{Shellwords.shellescape(source)} -type f -o -type d")
        unless list_result['exit_code'].zero?
          raise Bolt::Node::FileError.new(
            "Error listing directory on #{target.safe_name}: #{list_result['stderr']}",
            'READ_ERROR'
          )
        end

        paths = list_result['stdout'].split("\n").reject(&:empty?)

        paths.each do |remote_path|
          relative = remote_path.sub(%r{^#{Regexp.escape(source)}/?}, '')
          next if relative.empty?

          local_path = File.join(destination, relative)

          # Check if it's a directory
          type_result = choria_shell_run(target, "test -d #{Shellwords.shellescape(remote_path)} && echo dir || echo file")

          if type_result['stdout'].strip == 'dir'
            FileUtils.mkdir_p(local_path)
          else
            FileUtils.mkdir_p(File.dirname(local_path))
            download_single_file(target, remote_path, local_path)
          end
        end
      end

      # Downloads a single file from the target using base64 encoding.
      def download_single_file(target, source, destination)
        FileUtils.mkdir_p(File.dirname(destination))

        result = choria_shell_run(target, "base64 #{Shellwords.shellescape(source)}")
        unless result['exit_code'].zero?
          raise Bolt::Node::FileError.new(
            "Error downloading file from #{target.safe_name}: #{result['stderr']}",
            'READ_ERROR'
          )
        end

        encoded_content = result['stdout'].gsub(/\s+/, '')
        File.binwrite(destination, Base64.decode64(encoded_content))
      end

      # Executes a command on the target via the Choria shell agent's 'run' action.
      # Returns a hash with 'stdout', 'stderr', and 'exit_code' keys.
      def choria_shell_run(target, command)
        result = execute_choria_rpc(target, 'shell', 'run', { 'command' => command })

        unless result[:success]
          @logger.debug { "Choria shell run failed on #{target.safe_name}: #{result[:error]}" }
          return {
            'stdout' => '',
            'stderr' => result[:error] || 'Choria RPC request failed',
            'exit_code' => 1
          }
        end

        data = result[:data] || {}

        {
          'stdout' => data['stdout'] || '',
          'stderr' => data['stderr'] || '',
          'exit_code' => data['exitcode'] || 0
        }
      end

      # Ensures the MCollective configuration is loaded from the Choria client
      # config file. This method is idempotent and only loads config once.
      #
      # The config file is a standard MCollective/Choria client configuration
      # file that specifies NATS broker connection details, security settings,
      # collectives, and other MCollective parameters.
      #
      # @param transport_config [Hash] The target's transport configuration
      def ensure_mcollective_config(transport_config)
        return if @config_loaded

        config_file = transport_config['choria-config']
        mc_config = MCollective::Config.instance

        mc_config.loadconfig(config_file || MCollective::Util.default_options[:config])

        # Ensure our bundled DDL directory is in the libdir so agent DDLs
        # (shell, rpcutil) are always found
        mc_config.libdir.unshift(DDL_DIR) unless mc_config.libdir.include?(DDL_DIR)

        @config_loaded = true
      end

      # Returns a cached MCollective RPC client for the given agent.
      # Creates a new client if one doesn't exist for this agent yet.
      #
      # @param agent [String] The agent name (e.g., 'shell', 'rpcutil')
      # @param transport_config [Hash] The target's transport configuration
      # @return [MCollective::RPC::Client] The RPC client
      def get_rpc_client(agent, transport_config)
        ensure_mcollective_config(transport_config)

        @rpc_clients[agent] ||= begin
          options = MCollective::Util.default_options
          options[:timeout] = transport_config.fetch('connect-timeout', 10)
          options[:config] = transport_config['choria-config'] if transport_config['choria-config']

          client = MCollective::RPC::Client.new(agent, options: options)
          client.progress = false
          client
        end
      end

      # Executes a Choria RPC request against a single target using the
      # MCollective RPC client library (choria-mcorpc-support gem).
      #
      # Uses custom_request to target a specific host by identity filter,
      # bypassing Choria's broadcast discovery mechanism.
      #
      # @param target [Bolt::Target] The target to execute against
      # @param agent [String] The Choria agent name (e.g., 'shell', 'rpcutil')
      # @param action [String] The action to invoke (e.g., 'run', 'ping')
      # @param request_data [Hash] Key-value pairs to pass as action inputs
      # @return [Hash] A result hash with :success, :data, and :error keys
      def execute_choria_rpc(target, agent, action, request_data = {})
        config = target.transport_config

        @rpc_mutex.synchronize do
          client = get_rpc_client(agent, config)

          collective = config['collective']
          client.collective = collective if collective

          @logger.trace { "Executing Choria RPC: #{agent}##{action} on #{target.safe_name}" }

          # Convert string keys to symbols for MCollective DDL validation
          symbolized_data = request_data.transform_keys(&:to_sym)

          results = client.custom_request(
            action.to_s,
            symbolized_data,
            [target.host],
            { "identity" => target.host }
          )

          process_rpc_results(results, target)
        end
      rescue StandardError => e
        @logger.debug { "Choria RPC error on #{target.safe_name}: #{e.message}" }
        {
          success: false,
          data: nil,
          error: "Choria RPC error: #{e.message}"
        }
      end

      # Processes results from an MCollective RPC custom_request call.
      #
      # @param results [Array<MCollective::RPC::Result>] The RPC results
      # @param target [Bolt::Target] The target we were communicating with
      # @return [Hash] A result hash with :success, :data, and :error keys
      def process_rpc_results(results, target)
        if results.nil? || results.empty?
          return {
            success: false,
            data: nil,
            error: "No response received from #{target.safe_name}"
          }
        end

        result = results.first

        statuscode = result[:statuscode] || 0
        statusmsg = result[:statusmsg] || ''
        data = result[:data]

        if statuscode != 0
          return {
            success: false,
            data: data,
            error: "Choria RPC error (code #{statuscode}): #{statusmsg}"
          }
        end

        {
          success: true,
          data: data,
          error: nil
        }
      end
    end
  end
end
