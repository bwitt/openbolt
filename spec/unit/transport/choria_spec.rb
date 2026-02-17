# frozen_string_literal: true

require 'spec_helper'
require 'bolt/executor'
require 'bolt/inventory'
require 'bolt/config'
require 'bolt/plugin'
require 'bolt/transport/choria'
require 'bolt/task'

describe Bolt::Transport::Choria do
  let(:transport) { Bolt::Transport::Choria.new }

  let(:target_data) do
    {
      'targets' => [
        {
          'uri' => 'choria://node1.example.net',
          'config' => {
            'transport' => 'choria',
            'choria' => {
              'choria-config' => '/etc/choria/client.conf'
            }
          }
        }
      ]
    }
  end

  let(:config) { Bolt::Config.default }
  let(:plugins) { Bolt::Plugin.new(config, nil) }
  let(:inventory) do
    Bolt::Inventory.create_version(target_data, config.transport, config.transports, plugins)
  end
  let(:target) { inventory.get_targets('choria://node1.example.net').first }

  # Helper to stub a successful choria RPC response via execute_choria_rpc
  def stub_choria_success(stdout: '', stderr: '', exitcode: 0)
    allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                  success: true,
      data: {
        'stdout' => stdout,
        'stderr' => stderr,
        'exitcode' => exitcode
      },
      error: nil
                                                                })
  end

  # Helper to stub a failed choria RPC response
  def stub_choria_failure(error_msg: 'command failed')
    allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                  success: false,
      data: nil,
      error: error_msg
                                                                })
  end

  context 'provided_features' do
    it 'includes shell' do
      expect(transport.provided_features).to include('shell')
    end

    it 'returns only shell' do
      expect(transport.provided_features).to eq(['shell'])
    end
  end

  context '#run_command' do
    it 'runs a simple command and returns a Bolt::Result' do
      stub_choria_success(stdout: 'hello', stderr: '', exitcode: 0)

      result = transport.run_command(target, 'echo hello')
      expect(result).to be_a(Bolt::Result)
      expect(result.value['stdout']).to eq('hello')
      expect(result.value['stderr']).to eq('')
      expect(result.value['exit_code']).to eq(0)
      expect(result.action).to eq('command')
      expect(result.object).to eq('echo hello')
    end

    it 'returns a result with error for non-zero exit code' do
      stub_choria_success(stdout: '', stderr: 'not found', exitcode: 127)

      result = transport.run_command(target, 'badcommand')
      expect(result.value['exit_code']).to eq(127)
      expect(result.value).to include('_error')
    end

    it 'passes environment variables to the command' do
      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => 'bar', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_command(target, 'echo $FOO', { env_vars: { 'FOO' => 'bar' } })
      expect(commands_run.last).to include('/usr/bin/env')
      expect(commands_run.last).to include('FOO=bar')
    end

    it 'handles choria RPC failure gracefully' do
      stub_choria_failure

      result = transport.run_command(target, 'echo hello')
      expect(result.value['exit_code']).to eq(1)
    end
  end

  context '#run_script' do
    let(:script_path) { File.expand_path('../../fixtures/scripts/success.sh', __dir__) }

    before(:each) do
      stub_choria_success(stdout: 'script output', exitcode: 0)
      # Provide a real file for File.basename and upload to work with
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(script_path).and_return(false)
      allow(File).to receive(:binread).with(script_path).and_return("#!/bin/bash\necho hello")
      allow(File).to receive(:executable?).with(script_path).and_return(true)
    end

    it 'uploads the script and executes it' do
      result = transport.run_script(target, script_path, [])
      expect(result).to be_a(Bolt::Result)
      expect(result.action).to eq('script')
      expect(result.object).to eq(script_path)
      expect(result.value['stdout']).to eq('script output')
      expect(result.value['exit_code']).to eq(0)
    end

    it 'passes arguments to the script' do
      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_script(target, script_path, %w[arg1 arg2])
      exec_cmd = commands_run.find { |c| c.include?('arg1') }
      expect(exec_cmd).to include('arg1')
      expect(exec_cmd).to include('arg2')
    end

    it 'uses the configured interpreter' do
      target_data_interp = {
        'targets' => [
          {
            'uri' => 'choria://node1.example.net',
            'config' => {
              'transport' => 'choria',
              'choria' => {
                'interpreters' => { '.sh' => '/bin/bash' }
              }
            }
          }
        ]
      }
      inv = Bolt::Inventory.create_version(target_data_interp, config.transport, config.transports, plugins)
      tgt = inv.get_targets('choria://node1.example.net').first

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_script(tgt, script_path, [])
      exec_cmd = commands_run.find { |c| c.include?('/bin/bash') }
      expect(exec_cmd).not_to be_nil
    end
  end

  context '#run_task' do
    let(:task_executable) { File.expand_path('../../fixtures/modules/sample/tasks/noop.sh', __dir__) }
    let(:task) do
      task_double = instance_double(Bolt::Task)
      allow(task_double).to receive_messages(name: 'sample::noop', tasks_dir: 'sample/tasks', select_implementation: {
                                               'path' => task_executable,
          'input_method' => 'stdin',
          'files' => []
                                             })
      task_double
    end

    before(:each) do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(task_executable).and_return(false)
      allow(File).to receive(:binread).with(task_executable).and_return("#!/bin/bash\ncat")
      allow(File).to receive(:executable?).with(task_executable).and_return(true)
      stub_choria_success(stdout: '{"result": "success"}', exitcode: 0)
    end

    it 'uploads and runs the task executable' do
      result = transport.run_task(target, task, { 'message' => 'hello' })
      expect(result).to be_a(Bolt::Result)
      expect(result.action).to eq('task')
      expect(result.object).to eq('sample::noop')
      expect(result.value).to include('result' => 'success')
    end

    it 'passes arguments via stdin for stdin input method' do
      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '{"result":"ok"}', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_task(target, task, { 'message' => 'hello' })
      exec_cmd = commands_run.find { |c| c.include?('echo') && c.include?('|') }
      expect(exec_cmd).not_to be_nil
    end

    it 'sets environment variables for environment input method' do
      allow(task).to receive(:select_implementation).and_return(
        {
          'path' => task_executable,
          'input_method' => 'environment',
          'files' => []
        }
      )

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '{"result":"ok"}', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_task(target, task, { 'message' => 'hello' })
      exec_cmd = commands_run.find { |c| c.include?('PT_message') }
      expect(exec_cmd).not_to be_nil
    end

    it 'handles both input method (stdin + environment)' do
      allow(task).to receive(:select_implementation).and_return(
        {
          'path' => task_executable,
          'input_method' => 'both',
          'files' => []
        }
      )

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '{"result":"ok"}', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_task(target, task, { 'message' => 'hello' })
      exec_cmd = commands_run.find { |c| c.include?('PT_message') && c.include?('echo') }
      expect(exec_cmd).not_to be_nil
    end

    it 'uploads extra files when present' do
      extra_file_path = '/tmp/extra_file.txt'
      allow(task).to receive(:select_implementation).and_return(
        {
          'path' => task_executable,
          'input_method' => 'stdin',
          'files' => [{ 'name' => 'sample/lib/helper.rb', 'path' => extra_file_path }]
        }
      )
      allow(File).to receive(:directory?).with(extra_file_path).and_return(false)
      allow(File).to receive(:binread).with(extra_file_path).and_return('helper content')
      allow(File).to receive(:executable?).with(extra_file_path).and_return(false)

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '{"result":"ok"}', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_task(target, task, { 'message' => 'hello' })
      mkdir_cmds = commands_run.select { |c| c.include?('mkdir') }
      expect(mkdir_cmds.length).to be >= 2
    end

    it 'uses the configured interpreter for the task executable' do
      allow(task).to receive(:select_implementation).and_return(
        {
          'path' => task_executable,
          'input_method' => 'environment',
          'files' => []
        }
      )

      target_data_interp = {
        'targets' => [
          {
            'uri' => 'choria://node1.example.net',
            'config' => {
              'transport' => 'choria',
              'choria' => {
                'interpreters' => { '.sh' => '/bin/bash' }
              }
            }
          }
        ]
      }
      inv = Bolt::Inventory.create_version(target_data_interp, config.transport, config.transports, plugins)
      tgt = inv.get_targets('choria://node1.example.net').first

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '{"result":"ok"}', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_task(tgt, task, { 'message' => 'hello' })
      exec_cmd = commands_run.find { |c| c.include?('/bin/bash') && c.include?('noop') }
      expect(exec_cmd).not_to be_nil
    end

    it 'runs task without stdin or env when input_method is nil' do
      allow(task).to receive(:select_implementation).and_return(
        {
          'path' => task_executable,
          'input_method' => nil,
          'files' => []
        }
      )

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '{"result":"ok"}', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.run_task(target, task, { 'message' => 'hello' })
      exec_cmd = commands_run.last
      # Should NOT have stdin piping or PT_ env vars
      expect(exec_cmd).not_to include('echo')
      expect(exec_cmd).not_to include('PT_message')
    end
  end

  context '#upload' do
    it 'uploads a file and returns a Bolt::Result' do
      source = '/tmp/test_upload.txt'
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(source).and_return(false)
      allow(File).to receive(:binread).with(source).and_return('file content')
      allow(File).to receive(:executable?).with(source).and_return(false)
      stub_choria_success

      result = transport.upload(target, source, '/remote/path/test.txt')
      expect(result).to be_a(Bolt::Result)
      expect(result.action).to eq('upload')
      expect(result.object).to eq(source)
      expect(result.message).to include(source)
      expect(result.message).to include('/remote/path/test.txt')
    end

    it 'uploads a directory recursively' do
      source_dir = Dir.mktmpdir('bolt_test_upload')
      begin
        File.write(File.join(source_dir, 'file1.txt'), 'content1')
        sub_dir = File.join(source_dir, 'subdir')
        FileUtils.mkdir_p(sub_dir)
        File.write(File.join(sub_dir, 'file2.txt'), 'content2')

        stub_choria_success

        result = transport.upload(target, source_dir, '/remote/path')
        expect(result).to be_a(Bolt::Result)
        expect(result.action).to eq('upload')
        expect(result.object).to eq(source_dir)
      ensure
        FileUtils.rm_rf(source_dir)
      end
    end
  end

  context '#download' do
    it 'downloads a file and returns a Bolt::Result' do
      destination = Dir.mktmpdir('bolt_test_download')
      begin
        encoded = Base64.strict_encode64('remote file content')
        # First call: test -d check returns "file"
        # Second call: base64 of the file content
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          if cmd.include?('test -d')
            { 'stdout' => 'file', 'stderr' => '', 'exit_code' => 0 }
          else
            { 'stdout' => encoded, 'stderr' => '', 'exit_code' => 0 }
          end
        end

        result = transport.download(target, '/remote/file.txt', destination)
        expect(result).to be_a(Bolt::Result)
        expect(result.action).to eq('download')
        expect(result.object).to eq('/remote/file.txt')
        expect(result.value['path']).to eq(File.join(destination, 'file.txt'))
        expect(result.message).to include('/remote/file.txt')
      ensure
        FileUtils.rm_rf(destination)
      end
    end

    it 'downloads a directory recursively' do
      destination = Dir.mktmpdir('bolt_test_download_dir')
      begin
        call_count = 0
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          call_count += 1
          if cmd.include?('test -d') && call_count <= 1
            { 'stdout' => 'dir', 'stderr' => '', 'exit_code' => 0 }
          elsif cmd.include?('find')
            { 'stdout' => "/remote/dir\n/remote/dir/file1.txt\n/remote/dir/sub\n/remote/dir/sub/file2.txt",
              'stderr' => '', 'exit_code' => 0 }
          elsif cmd.include?('test -d')
            if cmd.include?('sub/file2') || cmd.include?('file1')
              { 'stdout' => 'file', 'stderr' => '', 'exit_code' => 0 }
            else
              { 'stdout' => 'dir', 'stderr' => '', 'exit_code' => 0 }
            end
          elsif cmd.include?('base64')
            { 'stdout' => Base64.strict_encode64('content'), 'stderr' => '', 'exit_code' => 0 }
          else
            { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
          end
        end

        result = transport.download(target, '/remote/dir', destination)
        expect(result).to be_a(Bolt::Result)
        expect(result.action).to eq('download')
        expect(result.object).to eq('/remote/dir')
        expect(result.value['path']).to eq(File.join(destination, 'dir'))
      ensure
        FileUtils.rm_rf(destination)
      end
    end
  end

  context '#connected?' do
    it 'returns true when rpcutil ping succeeds' do
      allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                    success: true,
        data: { 'pong' => 1_234_567_890 },
        error: nil
                                                                  })

      expect(transport.connected?(target)).to eq(true)
    end

    it 'returns false when rpcutil ping fails' do
      allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                    success: false,
        data: nil,
        error: 'timeout'
                                                                  })

      expect(transport.connected?(target)).to eq(false)
    end

    it 'returns false when an exception is raised' do
      allow(transport).to receive(:execute_choria_rpc).and_raise(StandardError, 'connection refused')

      expect(transport.connected?(target)).to eq(false)
    end
  end

  context '#build_env_prefix' do
    it 'returns empty string for nil env_vars' do
      expect(transport.send(:build_env_prefix, nil)).to eq('')
    end

    it 'returns empty string for empty env_vars' do
      expect(transport.send(:build_env_prefix, {})).to eq('')
    end

    it 'builds a /usr/bin/env prefix with escaped values' do
      result = transport.send(:build_env_prefix, { 'FOO' => 'bar', 'BAZ' => 'qux quux' })
      expect(result).to start_with('/usr/bin/env ')
      expect(result).to include('FOO=bar')
      expect(result).to include('BAZ=')
    end

    it 'shell-escapes values with special characters' do
      result = transport.send(:build_env_prefix, { 'VAR' => "val'ue" })
      expect(result).to include('/usr/bin/env')
      # The value should be escaped
      expect(result).not_to include("val'ue")
    end
  end

  context '#with_choria_env' do
    it 'yields the env prefix' do
      transport.send(:with_choria_env, target, { 'FOO' => 'bar' }) do |prefix|
        expect(prefix).to include('FOO=bar')
      end
    end

    it 'yields empty string when env_vars is nil' do
      transport.send(:with_choria_env, target, nil) do |prefix|
        expect(prefix).to eq('')
      end
    end
  end

  context '#with_remote_tmpdir' do
    it 'creates a temporary directory and yields its path' do
      stub_choria_success
      yielded_path = nil

      transport.send(:with_remote_tmpdir, target) do |dir|
        yielded_path = dir
      end

      expect(yielded_path).to match(%r{^/tmp/bolt-})
    end

    it 'uses configured tmpdir' do
      target_data_with_tmpdir = {
        'targets' => [
          {
            'uri' => 'choria://node1.example.net',
            'config' => {
              'transport' => 'choria',
              'choria' => {
                'choria-config' => '/etc/choria/client.conf',
                'tmpdir' => '/var/tmp'
              }
            }
          }
        ]
      }
      inv = Bolt::Inventory.create_version(target_data_with_tmpdir, config.transport, config.transports, plugins)
      tgt = inv.get_targets('choria://node1.example.net').first

      stub_choria_success
      yielded_path = nil

      transport.send(:with_remote_tmpdir, tgt) do |dir|
        yielded_path = dir
      end

      expect(yielded_path).to start_with('/var/tmp/bolt-')
    end

    it 'cleans up tmpdir after the block' do
      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.send(:with_remote_tmpdir, target) { |_dir| nil }

      cleanup_cmd = commands_run.find { |c| c.include?('rm -rf') }
      expect(cleanup_cmd).not_to be_nil
    end

    it 'skips cleanup when cleanup is false' do
      target_data_no_cleanup = {
        'targets' => [
          {
            'uri' => 'choria://node1.example.net',
            'config' => {
              'transport' => 'choria',
              'choria' => {
                'cleanup' => false
              }
            }
          }
        ]
      }
      inv = Bolt::Inventory.create_version(target_data_no_cleanup, config.transport, config.transports, plugins)
      tgt = inv.get_targets('choria://node1.example.net').first

      commands_run = []
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        commands_run << cmd
        { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
      end

      transport.send(:with_remote_tmpdir, tgt) { |_dir| nil }

      cleanup_cmd = commands_run.find { |c| c.include?('rm -rf') }
      expect(cleanup_cmd).to be_nil
    end

    it 'raises FileError when mkdir fails' do
      allow(transport).to receive(:choria_shell_run).and_return(
        { 'stdout' => '', 'stderr' => 'permission denied', 'exit_code' => 1 }
      )

      expect {
        transport.send(:with_remote_tmpdir, target) { |_dir| nil }
      }.to raise_error(Bolt::Node::FileError, /Could not create tmpdir/)
    end

    it 'cleans up tmpdir even when the block raises' do
      commands_run = []
      call_count = 0
      allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
        call_count += 1
        commands_run << cmd
        { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
      end

      expect {
        transport.send(:with_remote_tmpdir, target) { |_dir| raise 'boom' }
      }.to raise_error(RuntimeError, 'boom')

      cleanup_cmd = commands_run.find { |c| c.include?('rm -rf') }
      expect(cleanup_cmd).not_to be_nil
    end
  end

  context '#upload_single_file' do
    it 'uploads an empty file using touch' do
      source = Tempfile.new('bolt_test_empty')
      begin
        source.close

        commands_run = []
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          commands_run << cmd
          { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
        end

        transport.send(:upload_single_file, target, source.path, '/remote/empty.txt')
        expect(commands_run.any? { |c| c.include?('touch') }).to eq(true)
      ensure
        source.unlink
      end
    end

    it 'uploads file content in base64-encoded chunks' do
      source = Tempfile.new('bolt_test_content')
      begin
        source.write('test file content')
        source.close

        commands_run = []
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          commands_run << cmd
          { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
        end

        transport.send(:upload_single_file, target, source.path, '/remote/file.txt')
        base64_cmds = commands_run.select { |c| c.include?('base64 -d') }
        expect(base64_cmds.length).to be >= 1
        # First chunk should use > (overwrite)
        expect(base64_cmds.first).to include('>')
      ensure
        source.unlink
      end
    end

    it 'uses multiple chunks for large files' do
      source = Tempfile.new('bolt_test_large')
      begin
        # Write content larger than UPLOAD_CHUNK_SIZE
        large_content = 'x' * (Bolt::Transport::Choria::UPLOAD_CHUNK_SIZE + 100)
        source.binmode
        source.write(large_content)
        source.close

        commands_run = []
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          commands_run << cmd
          { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
        end

        transport.send(:upload_single_file, target, source.path, '/remote/large.bin')
        base64_cmds = commands_run.select { |c| c.include?('base64 -d') }
        # Should have at least 2 chunks
        expect(base64_cmds.length).to eq(2)
        # First chunk uses >, second uses >>
        expect(base64_cmds[0]).to include(' > ')
        expect(base64_cmds[1]).to include(' >> ')
      ensure
        source.unlink
      end
    end

    it 'preserves executable permissions' do
      source = Tempfile.new('bolt_test_exec')
      begin
        source.write('#!/bin/bash')
        source.close
        FileUtils.chmod(0o755, source.path)

        commands_run = []
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          commands_run << cmd
          { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
        end

        transport.send(:upload_single_file, target, source.path, '/remote/script.sh')
        chmod_cmds = commands_run.select { |c| c.include?('chmod u+x') }
        expect(chmod_cmds.length).to be >= 1
      ensure
        source.unlink
      end
    end

    it 'raises FileError on upload failure' do
      source = Tempfile.new('bolt_test_fail')
      begin
        source.write('content')
        source.close

        allow(transport).to receive(:choria_shell_run).and_return(
          { 'stdout' => '', 'stderr' => 'disk full', 'exit_code' => 1 }
        )

        expect {
          transport.send(:upload_single_file, target, source.path, '/remote/file.txt')
        }.to raise_error(Bolt::Node::FileError, /Error uploading file/)
      ensure
        source.unlink
      end
    end

    it 'raises FileError when touch fails for empty file' do
      source = Tempfile.new('bolt_test_empty_fail')
      begin
        source.close

        allow(transport).to receive(:choria_shell_run).and_return(
          { 'stdout' => '', 'stderr' => 'permission denied', 'exit_code' => 1 }
        )

        expect {
          transport.send(:upload_single_file, target, source.path, '/remote/empty.txt')
        }.to raise_error(Bolt::Node::FileError, /Error uploading file/)
      ensure
        source.unlink
      end
    end
  end

  context '#upload_directory_to_target' do
    it 'creates remote directory and uploads all files' do
      source_dir = Dir.mktmpdir('bolt_test_dir')
      begin
        File.write(File.join(source_dir, 'a.txt'), 'aaa')
        sub = File.join(source_dir, 'sub')
        FileUtils.mkdir_p(sub)
        File.write(File.join(sub, 'b.txt'), 'bbb')

        commands_run = []
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          commands_run << cmd
          { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
        end

        transport.send(:upload_directory_to_target, target, source_dir, '/remote/dir')

        mkdir_cmds = commands_run.select { |c| c.include?('mkdir') }
        expect(mkdir_cmds.length).to be >= 2 # top-level + sub
        base64_cmds = commands_run.select { |c| c.include?('base64') }
        expect(base64_cmds.length).to eq(2) # a.txt + b.txt
      ensure
        FileUtils.rm_rf(source_dir)
      end
    end
  end

  context '#upload_file_to_target' do
    it 'dispatches to upload_single_file for a regular file' do
      source = Tempfile.new('bolt_test_dispatch_file')
      begin
        source.write('content')
        source.close

        expect(transport).to receive(:upload_single_file).with(target, source.path, '/remote/file.txt')
        transport.send(:upload_file_to_target, target, source.path, '/remote/file.txt')
      ensure
        source.unlink
      end
    end

    it 'dispatches to upload_directory_to_target for a directory' do
      source_dir = Dir.mktmpdir('bolt_test_dispatch_dir')
      begin
        expect(transport).to receive(:upload_directory_to_target).with(target, source_dir, '/remote/dir')
        transport.send(:upload_file_to_target, target, source_dir, '/remote/dir')
      ensure
        FileUtils.rm_rf(source_dir)
      end
    end
  end

  context '#download_single_file' do
    it 'downloads and decodes base64 content' do
      destination = File.join(Dir.mktmpdir('bolt_test_dl'), 'file.txt')
      begin
        content = 'downloaded content'
        encoded = Base64.strict_encode64(content)

        allow(transport).to receive(:choria_shell_run).and_return(
          { 'stdout' => encoded, 'stderr' => '', 'exit_code' => 0 }
        )

        transport.send(:download_single_file, target, '/remote/file.txt', destination)
        expect(File.read(destination)).to eq(content)
      ensure
        FileUtils.rm_rf(File.dirname(destination))
      end
    end

    it 'raises FileError on download failure' do
      destination = File.join(Dir.mktmpdir('bolt_test_dl_fail'), 'file.txt')
      begin
        allow(transport).to receive(:choria_shell_run).and_return(
          { 'stdout' => '', 'stderr' => 'no such file', 'exit_code' => 1 }
        )

        expect {
          transport.send(:download_single_file, target, '/remote/missing.txt', destination)
        }.to raise_error(Bolt::Node::FileError, /Error downloading file/)
      ensure
        FileUtils.rm_rf(File.dirname(destination))
      end
    end
  end

  context '#download_directory_from_target' do
    it 'raises FileError when find fails' do
      destination = Dir.mktmpdir('bolt_test_dl_dir_fail')
      begin
        allow(transport).to receive(:choria_shell_run).and_return(
          { 'stdout' => '', 'stderr' => 'permission denied', 'exit_code' => 1 }
        )

        expect {
          transport.send(:download_directory_from_target, target, '/remote/dir', destination)
        }.to raise_error(Bolt::Node::FileError, /Error listing directory/)
      ensure
        FileUtils.rm_rf(destination)
      end
    end

    it 'downloads all files and creates directories' do
      destination = Dir.mktmpdir('bolt_test_dl_dir_ok')
      begin
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          if cmd.include?('find')
            { 'stdout' => "/remote/dir\n/remote/dir/file1.txt\n/remote/dir/sub\n/remote/dir/sub/file2.txt",
              'stderr' => '', 'exit_code' => 0 }
          elsif cmd.include?('test -d')
            if cmd.include?('file1') || cmd.include?('file2')
              { 'stdout' => 'file', 'stderr' => '', 'exit_code' => 0 }
            else
              { 'stdout' => 'dir', 'stderr' => '', 'exit_code' => 0 }
            end
          elsif cmd.include?('base64')
            { 'stdout' => Base64.strict_encode64('content'), 'stderr' => '', 'exit_code' => 0 }
          else
            { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
          end
        end

        transport.send(:download_directory_from_target, target, '/remote/dir', destination)

        expect(File.exist?(File.join(destination, 'file1.txt'))).to eq(true)
        expect(File.directory?(File.join(destination, 'sub'))).to eq(true)
        expect(File.exist?(File.join(destination, 'sub', 'file2.txt'))).to eq(true)
        expect(File.read(File.join(destination, 'file1.txt'))).to eq('content')
      ensure
        FileUtils.rm_rf(destination)
      end
    end
  end

  context '#download_file_from_target' do
    it 'dispatches to download_single_file for files' do
      destination = File.join(Dir.mktmpdir('bolt_test_dispatch'), 'file.txt')
      begin
        encoded = Base64.strict_encode64('content')
        call_count = 0
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          call_count += 1
          if cmd.include?('test -d')
            { 'stdout' => 'file', 'stderr' => '', 'exit_code' => 0 }
          else
            { 'stdout' => encoded, 'stderr' => '', 'exit_code' => 0 }
          end
        end

        transport.send(:download_file_from_target, target, '/remote/file.txt', destination)
        expect(File.exist?(destination)).to eq(true)
      ensure
        FileUtils.rm_rf(File.dirname(destination))
      end
    end

    it 'dispatches to download_directory_from_target for directories' do
      destination = Dir.mktmpdir('bolt_test_dispatch_dir')
      begin
        commands_run = []
        allow(transport).to receive(:choria_shell_run).and_wrap_original do |_method, _tgt, cmd|
          commands_run << cmd
          if cmd.include?('test -d') && !cmd.include?('file1')
            { 'stdout' => 'dir', 'stderr' => '', 'exit_code' => 0 }
          elsif cmd.include?('find')
            { 'stdout' => "/remote/dir\n/remote/dir/file1.txt", 'stderr' => '', 'exit_code' => 0 }
          elsif cmd.include?('test -d')
            { 'stdout' => 'file', 'stderr' => '', 'exit_code' => 0 }
          elsif cmd.include?('base64')
            { 'stdout' => Base64.strict_encode64('data'), 'stderr' => '', 'exit_code' => 0 }
          else
            { 'stdout' => '', 'stderr' => '', 'exit_code' => 0 }
          end
        end

        transport.send(:download_file_from_target, target, '/remote/dir', destination)
        expect(commands_run.any? { |c| c.include?('find') }).to eq(true)
      ensure
        FileUtils.rm_rf(destination)
      end
    end
  end

  context '#execute_choria_rpc' do
    let(:mock_rpc_client) { double('MCollective::RPC::Client') }

    before do
      allow(mock_rpc_client).to receive(:progress=)
      allow(mock_rpc_client).to receive(:collective=)

      # Stub the internal get_rpc_client to return our mock
      allow(transport).to receive(:get_rpc_client).and_return(mock_rpc_client)
    end

    it 'calls custom_request with correct parameters' do
      mock_result = { statuscode: 0, statusmsg: 'OK', data: { 'pong' => 123 } }

      expect(mock_rpc_client).to receive(:custom_request).with(
        'ping',
        {},
        ['node1.example.net'],
        { 'identity' => 'node1.example.net' }
      ).and_return([mock_result])

      result = transport.send(:execute_choria_rpc, target, 'rpcutil', 'ping')
      expect(result[:success]).to eq(true)
      expect(result[:data]).to eq({ 'pong' => 123 })
    end

    it 'converts request data keys to symbols' do
      mock_result = { statuscode: 0, statusmsg: 'OK', data: { 'stdout' => 'hello' } }

      expect(mock_rpc_client).to receive(:custom_request).with(
        'run',
        { command: 'echo hello' },
        ['node1.example.net'],
        { 'identity' => 'node1.example.net' }
      ).and_return([mock_result])

      result = transport.send(:execute_choria_rpc, target, 'shell', 'run', { 'command' => 'echo hello' })
      expect(result[:success]).to eq(true)
    end

    it 'sets collective when configured' do
      target_data_collective = {
        'targets' => [
          {
            'uri' => 'choria://node1.example.net',
            'config' => {
              'transport' => 'choria',
              'choria' => {
                'collective' => 'production'
              }
            }
          }
        ]
      }
      inv = Bolt::Inventory.create_version(target_data_collective, config.transport, config.transports, plugins)
      tgt = inv.get_targets('choria://node1.example.net').first

      mock_result = { statuscode: 0, statusmsg: 'OK', data: {} }
      allow(mock_rpc_client).to receive(:custom_request).and_return([mock_result])

      expect(mock_rpc_client).to receive(:collective=).with('production')

      transport.send(:execute_choria_rpc, tgt, 'rpcutil', 'ping')
    end

    it 'does not set collective when not configured' do
      target_data_no_collective = {
        'targets' => [
          {
            'uri' => 'choria://node1.example.net',
            'config' => {
              'transport' => 'choria',
              'choria' => {}
            }
          }
        ]
      }
      inv = Bolt::Inventory.create_version(target_data_no_collective, config.transport, config.transports, plugins)
      tgt = inv.get_targets('choria://node1.example.net').first

      mock_result = { statuscode: 0, statusmsg: 'OK', data: {} }
      allow(mock_rpc_client).to receive(:custom_request).and_return([mock_result])

      expect(mock_rpc_client).not_to receive(:collective=)

      transport.send(:execute_choria_rpc, tgt, 'rpcutil', 'ping')
    end

    it 'returns failure when no results returned' do
      allow(mock_rpc_client).to receive(:custom_request).and_return([])

      result = transport.send(:execute_choria_rpc, target, 'rpcutil', 'ping')
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('No response received')
    end

    it 'returns failure when nil results returned' do
      allow(mock_rpc_client).to receive(:custom_request).and_return(nil)

      result = transport.send(:execute_choria_rpc, target, 'rpcutil', 'ping')
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('No response received')
    end

    it 'returns failure on non-zero statuscode' do
      mock_result = { statuscode: 5, statusmsg: 'Unknown error', data: {} }
      allow(mock_rpc_client).to receive(:custom_request).and_return([mock_result])

      result = transport.send(:execute_choria_rpc, target, 'rpcutil', 'ping')
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('code 5')
    end

    it 'handles exceptions gracefully' do
      allow(mock_rpc_client).to receive(:custom_request).and_raise(StandardError, 'NATS connection failed')

      result = transport.send(:execute_choria_rpc, target, 'rpcutil', 'ping')
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('NATS connection failed')
    end
  end

  context '#choria_shell_run' do
    it 'returns stdout, stderr, and exit_code from shell agent response' do
      allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                    success: true,
        data: {
          'stdout' => 'hello world',
          'stderr' => '',
          'exitcode' => 0
        },
        error: nil
                                                                  })

      result = transport.send(:choria_shell_run, target, 'echo hello world')
      expect(result['stdout']).to eq('hello world')
      expect(result['stderr']).to eq('')
      expect(result['exit_code']).to eq(0)
    end

    it 'handles failed choria RPC calls' do
      allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                    success: false,
        data: nil,
        error: 'connection refused'
                                                                  })

      result = transport.send(:choria_shell_run, target, 'echo hello')
      expect(result['exit_code']).to eq(1)
      expect(result['stderr']).to include('connection refused')
    end

    it 'returns defaults when data keys are missing' do
      allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                    success: true,
        data: {},
        error: nil
                                                                  })

      result = transport.send(:choria_shell_run, target, 'true')
      expect(result['stdout']).to eq('')
      expect(result['stderr']).to eq('')
      expect(result['exit_code']).to eq(0)
    end

    it 'returns defaults when data is nil' do
      allow(transport).to receive(:execute_choria_rpc).and_return({
                                                                    success: true,
        data: nil,
        error: nil
                                                                  })

      result = transport.send(:choria_shell_run, target, 'true')
      expect(result['stdout']).to eq('')
      expect(result['stderr']).to eq('')
      expect(result['exit_code']).to eq(0)
    end
  end

  context '#process_rpc_results' do
    it 'returns success for statuscode 0' do
      results = [{ statuscode: 0, statusmsg: 'OK', data: { 'stdout' => 'output' } }]
      result = transport.send(:process_rpc_results, results, target)
      expect(result[:success]).to eq(true)
      expect(result[:data]['stdout']).to eq('output')
    end

    it 'returns failure for non-zero statuscode' do
      results = [{ statuscode: 5, statusmsg: 'Unknown error', data: {} }]
      result = transport.send(:process_rpc_results, results, target)
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('code 5')
    end

    it 'returns failure for nil results' do
      result = transport.send(:process_rpc_results, nil, target)
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('No response received')
    end

    it 'returns failure for empty results' do
      result = transport.send(:process_rpc_results, [], target)
      expect(result[:success]).to eq(false)
      expect(result[:error]).to include('No response received')
    end

    it 'defaults statuscode to 0 when missing' do
      results = [{ statusmsg: 'OK', data: { 'val' => 1 } }]
      result = transport.send(:process_rpc_results, results, target)
      expect(result[:success]).to eq(true)
    end

    it 'uses first result from array' do
      results = [
        { statuscode: 0, statusmsg: 'OK', data: { 'val' => 'first' } },
        { statuscode: 0, statusmsg: 'OK', data: { 'val' => 'second' } }
      ]
      result = transport.send(:process_rpc_results, results, target)
      expect(result[:data]['val']).to eq('first')
    end
  end

  context '#ensure_mcollective_config' do
    let(:mock_mc_config) { double('MCollective::Config') }
    let(:default_config_path) { '/etc/puppetlabs/mcollective/client.cfg' }

    before do
      transport.instance_variable_set(:@config_loaded, false)
      allow(MCollective::Config).to receive(:instance).and_return(mock_mc_config)
      allow(mock_mc_config).to receive(:loadconfig)
      allow(mock_mc_config).to receive_messages(libdir: [], default_discovery_options: [])
      allow(MCollective::Util).to receive(:default_options).and_return({
                                                                         verbose: false, timeout: 5, config: default_config_path
                                                                       })
    end

    it 'loads config from the specified file' do
      expect(mock_mc_config).to receive(:loadconfig).with('/etc/choria/client.conf')

      transport.send(:ensure_mcollective_config, { 'choria-config' => '/etc/choria/client.conf' })
    end

    it 'uses default config path when no file specified' do
      expect(mock_mc_config).to receive(:loadconfig).with(default_config_path)

      transport.send(:ensure_mcollective_config, {})
    end

    it 'adds DDL_DIR to libdir' do
      libdir = []
      allow(mock_mc_config).to receive(:libdir).and_return(libdir)

      transport.send(:ensure_mcollective_config, {})
      expect(libdir).to include(Bolt::Transport::Choria::DDL_DIR)
    end

    it 'only loads config once (idempotent)' do
      expect(mock_mc_config).to receive(:loadconfig).once

      transport.send(:ensure_mcollective_config, {})
      transport.send(:ensure_mcollective_config, {})
    end

    it 'does not duplicate DDL_DIR in libdir' do
      libdir = [Bolt::Transport::Choria::DDL_DIR]
      allow(mock_mc_config).to receive(:libdir).and_return(libdir)

      transport.send(:ensure_mcollective_config, {})
      expect(libdir.count(Bolt::Transport::Choria::DDL_DIR)).to eq(1)
    end
  end

  context '#get_rpc_client' do
    let(:mock_mc_config) { double('MCollective::Config') }
    let(:mock_rpc_client) { double('MCollective::RPC::Client') }

    before do
      transport.instance_variable_set(:@config_loaded, false)
      transport.instance_variable_set(:@rpc_clients, {})
      allow(MCollective::Config).to receive(:instance).and_return(mock_mc_config)
      allow(mock_mc_config).to receive(:loadconfig)
      allow(mock_mc_config).to receive(:libdir).and_return([])
      allow(MCollective::Util).to receive(:default_options).and_return({
                                                                         verbose: false, timeout: 5, config: '/etc/puppetlabs/mcollective/client.cfg'
                                                                       })
      allow(MCollective::RPC::Client).to receive(:new).and_return(mock_rpc_client)
      allow(mock_rpc_client).to receive(:progress=)
    end

    it 'creates a new RPC client for the agent' do
      expect(MCollective::RPC::Client).to receive(:new).with(
        'shell',
        hash_including(options: hash_including(timeout: 10))
      ).and_return(mock_rpc_client)

      client = transport.send(:get_rpc_client, 'shell', { 'connect-timeout' => 10 })
      expect(client).to eq(mock_rpc_client)
    end

    it 'caches the client for subsequent calls' do
      expect(MCollective::RPC::Client).to receive(:new).once.and_return(mock_rpc_client)

      client1 = transport.send(:get_rpc_client, 'shell', {})
      client2 = transport.send(:get_rpc_client, 'shell', {})
      expect(client1).to equal(client2)
    end

    it 'creates separate clients for different agents' do
      shell_client = double('shell_client')
      rpcutil_client = double('rpcutil_client')
      allow(shell_client).to receive(:progress=)
      allow(rpcutil_client).to receive(:progress=)

      allow(MCollective::RPC::Client).to receive(:new).with('shell', anything).and_return(shell_client)
      allow(MCollective::RPC::Client).to receive(:new).with('rpcutil', anything).and_return(rpcutil_client)

      client1 = transport.send(:get_rpc_client, 'shell', {})
      client2 = transport.send(:get_rpc_client, 'rpcutil', {})
      expect(client1).not_to equal(client2)
    end

    it 'sets progress to false on the client' do
      expect(mock_rpc_client).to receive(:progress=).with(false)

      transport.send(:get_rpc_client, 'shell', {})
    end

    it 'passes choria-config to the options' do
      expect(MCollective::RPC::Client).to receive(:new).with(
        'shell',
        hash_including(options: hash_including(config: '/etc/choria/client.conf'))
      ).and_return(mock_rpc_client)

      transport.send(:get_rpc_client, 'shell', { 'choria-config' => '/etc/choria/client.conf' })
    end
  end
end
