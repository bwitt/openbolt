metadata :name        => "shell",
         :description => "Run commands via the Choria Shell agent",
         :author      => "Choria Project",
         :license     => "Apache-2.0",
         :version     => "1.0.0",
         :url         => "https://choria.io",
         :timeout     => 60

action "run", :description => "Runs a shell command" do
  display :always

  input :command,
        :prompt      => "Command",
        :description => "The shell command to execute",
        :type        => :string,
        :validation  => ".*",
        :optional    => false,
        :maxlength   => 0

  output :stdout,
         :description => "The STDOUT output from the command",
         :display_as  => "STDOUT",
         :default     => ""

  output :stderr,
         :description => "The STDERR output from the command",
         :display_as  => "STDERR",
         :default     => ""

  output :exitcode,
         :description => "The exit code of the command",
         :display_as  => "Exit Code",
         :default     => 0
end
