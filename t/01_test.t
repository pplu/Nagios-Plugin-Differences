

use Nagios::Plugin::Differences;

my $np = Nagios::Plugin::Differences->new( usage => 'test' );

$np->add_arg(
     spec => 'warning|w=s',
     help => '-w, --warning=INTEGER:INTEGER .  See '
       . 'http://nagiosplug.sourceforge.net/developer-guidelines.html#THRESHOLDFORMAT '
       . 'for the threshold format. ',
   );

$np->getopts;



