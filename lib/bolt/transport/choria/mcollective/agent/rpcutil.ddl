metadata :name        => "rpcutil",
         :description => "General helpful actions that expose stats and utilities of the MCollective Server",
         :author      => "R.I.Pienaar <rip@devco.net>",
         :license     => "Apache-2.0",
         :version     => "1.0.0",
         :url         => "https://choria.io",
         :timeout     => 10

action "ping", :description => "Responds to a ping with the current local timestamp" do
  display :always

  output :pong,
         :description => "The local timestamp",
         :display_as  => "Timestamp",
         :default     => 0
end
