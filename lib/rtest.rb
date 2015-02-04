#!/usr/env ruby

require 'net/ssh'
require 'net/scp'
require 'optparse'

class RemoteTest

  SATELLITES_NAME   = 'satellites'
  REPOSITORIES_NAME = 'repositories'

  # Remote shell code

  # Format arguments
  # {
  #   :application_home => 'application data directory'
  # }
  REMOTE_COMMON_SNIPPET = <<-SNIPPET
export REMOTE_TEST=%{application_home}
export REMOTE_TEST_SATELLITES=$REMOTE_TEST/#{SATELLITES_NAME}
export REMOTE_TEST_REPOS=$REMOTE_TEST/#{REPOSITORIES_NAME}
SNIPPET

  # Format arguments
  # {
  #   :repo_name => 'repository name'
  # }
  # Also see REMOTE_COMMON_SNIPPET
  REMOTE_CONFIG_AUTOMATOR = <<-SNIPPET
#!/bin/bash

uname -a

#{REMOTE_COMMON_SNIPPET}

if [ ! -d $REMOTE_TEST ]
  then
  mkdir -p $REMOTE_TEST
fi

if [ ! -d $REMOTE_TEST_SATELLITES ]
  then
  mkdir -p $REMOTE_TEST_SATELLITES
fi

if [ ! -d $REMOTE_TEST_REPOS ]
  then
  mkdir -p $REMOTE_TEST_REPOS
fi

cd $REMOTE_TEST_REPOS

export GIT_DIR=%{repo_name}.git

if [ ! -d $GIT_DIR ]
  then
    git init
elif [[ -e $GIT_DIR && ! -d $GIT_DIR ]]
  then
    echo "$PWD/$GIT_DIR exists, but is not a folder"
    exit 1
fi

if [ -d $GIT_DIR ]
  then
    git --bare update-server-info
    exit 0
fi
SNIPPET

  # Format arguments
  # {
  #   :repo_name => 'repository name',
  #   :config_name => 'configuration file name'
  # }
  # Also see REMOTE_COMMON_SNIPPET
  REMOTE_UPDATE_HOOK = <<-HOOK
#!/bin/bash

#{REMOTE_COMMON_SNIPPET}

unset GIT_DIR

refname=$(git rev-parse --symbolic --abbrev-ref $1)

cd $REMOTE_TEST_SATELLITES

echo "Preparing satellite repository for testing on branch $refname"

rm -rf %{repo_name}

git clone --recursive $REMOTE_TEST_REPOS/%{repo_name}.git

cd %{repo_name}

source %{config_name}

if [[ ! -d $scripts_dir || ! -x $test_script ]]
  then
    echo "Configuration error (no directory, or script unusable)"
    exit 1
fi

test_exit_status=$(exec $test_script "$PWD")

if [ -e $after_script ]
  then
    $(exec $after_script $test_exit_status)
fi

echo "Testing completed. Script existed with status $test_exit_status."
cd ..
rm -rf %{repo_name}

exit $test_exit_status
HOOK

  # Format aguments
  # {
  #   :script_dir => 'name of the script directory'
  # }
  LOCAL_CONFIGURATION_FILE = <<-SNIPPET
#!/bin/bash
# This is an example, please edit the specified files and, optionally, this file.

scripts_dir=%{script_dir}
test_script=$scripts_dir/test.sh
after_script=$scripts_dir/after.sh
SNIPPET

# No format arguments
LOCAL_TEST_INIT = <<-SNIPPET
#!/bin/bash

git_repo_root=$0

echo "Testing is not configured"
exit 1
SNIPPET

# No format arguments
LOCAL_TEST_AFTER = <<-SNIPPET
#!/bin/bash

test_exit_status=$0

echo "Test finished with exit status $test_exit_status"
SNIPPET

  # Format arguments:
  # {
  #   :local => 'local repository path',
  #   :remote_name => 'git remote name',
  #   :remote_uri => 'remote repository',
  #   :config_tmp => 'tmp configuration file name',
  #   :config_name => 'final configuration file name',
  #   :scripts_tmp => 'tmp script directory name',
  #   :script_dir => 'final script directory name'
  # }
  LOCAL_CONFIG_AUTOMATOR = <<-SNIPPET
#!/bin/bash

echo "setting up %{local} repository for test builds"

if [ ! -d %{local}/.git ]
  then
    echo "%{local} is not a (full) git repository"
    exit 1
fi

cd %{local}

git remote add %{remote_name} %{remote_uri}

if [ ! -f %{config_name} ]
  then
    mv %{config_tmp} %{config_name}
fi
if [ ! -d %{script_dir} ]
  then
    mv %{scripts_tmp} %{script_dir}
fi

git add %{config_name}
git add %{script_dir}

echo "setup complete"
exit 0
SNIPPET

  # Begin ruby code
  VERSION='0.1'
  SCRIPT_HELP = <<-HELP
Remote-Test #{VERSION}, by Roman Hargrave
Automates testing on a remote server.
You need a shell on the server, and write privileges in the
directory that you want to store the code in.

Usage:
  rtest [options] --host <host> [--user user]

Options:
  -l, --local-repo    Local repository path (default: '$PWD')
  --remote-repo       Remote repository path
                      Defaults to
                        <ssh remote>:[app_dir]/satellites/[name].git
                      Where app dir is specific by --app-dir
                      and is specified by --repo-name
  -r, --remote        Git remote name (default remote_test)
  -c, --config        Configuration file name (default rtest.conf)
  -d, --script-dir    Script directory (default .rtest/)
  -n, --repo-name     Remote repository name
  --app-dir           Application remote data directory
                      This is the remote directory wherein repos
                      and satellites are stored.
                      Default value is $HOME/.remote_test

  --dry               Initialise scripts, but do not execute them

  --host              Remote host to connect to
  --user              User to connect as
  --pkey              SSH Key to use for authentication.
HELP

  def initialize
    @options = {
      :application_home => '$HOME/.remote_test',
      :repo_name        => File.basename(ENV['PWD']),
      :config_name      => 'remote_test.cfg',
      :user             => ENV['USER'],
      :local            => ENV['PWD'],
      :remote_name      => 'remote_test',
      :config_name      => 'remote_test.cfg',
      :script_dir       => '.rtest',
      :remote_uri       => nil, # Set in main method
      :config_tmp       => nil, # Set in main method
      :scripts_tmp      => nil, # Set in main method
    }
    @rt_options = {}
    @option_parser = OptionParser.new do |opts|
      opts.on('--host HOST') do |value|
        @options[:host] = value
      end

      opts.on('--user USER') do |value|
        @options[:user] = value
      end

      opts.on('-l REPO', '--local-repo REPO') do |value|
        @options[:local] = value
      end

      opts.on('--remote-repo REPO') do |value|
        @options[:remote_uri] = value
      end

      opts.on('-r NAME', '--remote NAME') do |value|
        @options[:remote_name] = value
      end

      opts.on('-c CFG', '--config CFG') do |value|
        @options[:config_name] = value
      end

      opts.on('-d DIR', '--script-dir DIR') do |value|
        @options[:script_dir] = value
      end

      opts.on('-n NAME', '--repo-name NAME') do |value|
        @options[:repo_name] = value
      end

      opts.on('--app-dir DIR') do |value|
        @options[:application_home] = value
      end

      opts.on('--dry') do |value|
        @rt_options[:dry_run] = true
      end

      opts.on('--password PWD') do |value|
        @rt_options[:password] =
          if value.is_a? String
            value
          else
            print 'SSH/PKey Password: '
            gets.chomp
          end
      end

      opts.on('--pkey [PATH]') do |value|
        @rt_options[:pkey] = value
      end

      opts.on('-h', '--help') do |v|
        display_help
        exit
      end
    end
  end

  def display_help
    puts SCRIPT_HELP
  end

  # Begin script RT

  def main
    @option_parser.parse!(ARGV)
    @dry_run = @rt_options[:dry_run]
    # puts @options,@rt_options

    if @options.empty? && @rt_options.empty?
      display_help
      exit
    end

    unless @options[:host]
      Kernel.abort "No host specified. Use -h for help."
    end

    repo_path =
      %{#{@options[:application_home]}/#{REPOSITORIES_NAME}/#{@options[:repo_name]}.git}

    puts "Connecting to #{@options[:host]}"

    ssh_opts = {:verbose => :warn}
    ssh_opts[:keys]     =
      [@rt_options[:pkey], "#{ENV['HOME']}/.ssh/id_rsa"] if @rt_options[:pkey]
    ssh_opts[:password] = [@rt_options[:password]] if @rt_options[:password]

    @remote = Net::SSH.start(@options[:host], @options[:user], ssh_opts)
    @scp    = Net::SCP.start(@options[:host], @options[:user], ssh_opts)


    puts "Creating bootstrap scripts on server"

    puts "- Getting environment variables"
    @remote.exec!("echo $USER,$HOME") do |chan, stream, data|
      @user,@home = data.chomp.split(',')
      chan.close
    end

    config_script = "/tmp/rt_cfg.#{@user}.sh"
    update_hook   = "/tmp/rt_hook.#{@user}.sh"

    puts "- Installer script (#{config_script})"

    @scp.upload! StringIO.new(REMOTE_CONFIG_AUTOMATOR % @options), config_script

    puts "- Git Update Hook (#{update_hook})"

    @scp.upload! StringIO.new(REMOTE_UPDATE_HOOK % @options), update_hook

    # Run installers on remote

    puts "Configuring remote environment"

    [ "chmod +x #{config_script} #{update_hook}",
      "exec #{config_script}",
      "rm #{config_script}",
      "mv #{update_hook} #{repo_path}/hooks/post-update",
      "chmod +x #{repo_path}/hooks/post-update" ].each do |command|
        puts "- #{command}"
        unless @dry_run
          ssh_exec!(@remote, command) do |output, code, signal|
            output.each_line { |line|
              puts "| - #{line}"
            }

            abort "| - Command return non-zero exit code #{code} #{signal}" if code != 0
          end
        end
    end

    # Add goods to local git repository

    puts "Configuring local environment"

    local_config_script = %{/tmp/rt_bootstrap_#{ENV['USER']}.sh}
    local_config        = %{/tmp/rt_config_#{ENV['USER']}.cfg}
    local_script_dir    = %{/tmp/rt_scripts_#{ENV['USER']}}
    local_test_script   = %{#{local_script_dir}/test.sh}
    local_after_script  = %{#{local_script_dir}/after.sh}

    puts "- Writing local bootstrap script (#{local_config_script})"
    File.open(local_config_script, 'w') do |f|
      f.puts LOCAL_CONFIG_AUTOMATOR % @options.merge({
        :config_tmp   => local_config,
        :scripts_tmp  => local_script_dir,
        :remote_uri   => %{#{@options[:user]}@#{@options[:host]}:#{repo_path}}
      })
    end
    `chmod +x #{local_config_script}`

    puts "- Creating scripts (in #{local_script_dir})"
    begin
      Dir.mkdir local_script_dir
    rescue; end
    File.open(local_config, 'w') do |f|
      f.puts LOCAL_CONFIGURATION_FILE % @options
    end
    File.open(local_test_script, 'w') do |f|
      f.puts LOCAL_TEST_INIT % @options
    end
    File.open(local_after_script, 'w') do |f|
      f.puts LOCAL_TEST_AFTER % @options
    end

    puts "- Running local bootstrap script"
    unless @dry_run
      if system("exec #{local_config_script}")
        `rm #{local_config_script}`
      else
        abort "Bootstrapper returned non-zero exit. See output for details"
      end
    end

    puts "Done."
    puts "You may test remotely using `git push #{@options[:remote_name]}`"
  end


  def ssh_exec!(ssh, command, &block)
    stdout_data = ""
    stderr_data = ""
    output = ""
    exit_code = nil
    exit_signal = nil
    ssh.open_channel do |channel|
      channel.exec(command) do |ch, success|
        unless success
          abort "FAILED: couldn't execute command (ssh.channel.exec)"
        end

        channel.on_data do |ch,data|
          stdout_data += data
          output += data
        end

        channel.on_extended_data do |ch,type,data|
          stderr_data += data
          output += data
        end

        channel.on_request("exit-status") do |ch,data|
          exit_code = data.read_long
        end

        channel.on_request("exit-signal") do |ch, data|
          exit_signal = data.read_long
        end
      end
    end
    ssh.loop

    if block
      block.call(output, exit_code, exit_signal)
    else
      [stdout_data, stderr_data, exit_code, exit_signal]
    end
  end

end

RemoteTest.new.main
