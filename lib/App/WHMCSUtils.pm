 package App::WHMCSUtils;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use File::chdir;
use IPC::System::Options qw(system readpipe);
use Path::Tiny;

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'CLI utilities related to WHMCS',
};

$SPEC{restore_whmcs_client} = {
    v => 1.1,
    summary => "Restore a missing client from SQL database backup",
    args => {
        sql_backup_file => {
            schema => 'filename*',
            description => <<'_',

Can accept either `.sql` or `.sql.gz`.

Will be converted first to a directory where the SQL file will be extracted to
separate files on a per-table basis.

_
        },
        sql_backup_dir => {
            summary => 'Directory containing per-table SQL files',
            schema => 'dirname*',
            description => <<'_',


_
        },
        client_email => {
            schema => 'str*',
        },
        client_id => {
            schema => 'posint*',
        },
        restore_invoices => {
            schema => 'bool*',
            default => 1,
        },
        restore_hostings => {
            schema => 'bool*',
            default => 1,
        },
        restore_domains => {
            schema => 'bool*',
            default => 1,
        },
    },
    args_rels => {
        'req_one&' => [
            ['sql_backup_file', 'sql_backup_dir'],
            ['client_email', 'client_id'],
        ],
    },
    deps => {
        prog => "mysql-sql-dump-extract-tables",
    },
    features => {
        dry_run => 1,
    },
};
sub restore_whmcs_client {

    my %args = @_;

    local $CWD;

    my $sql_backup_dir;
    my $decompress = 0;
    if ($args{sql_backup_file}) {
        return [404, "No such file: $args{sql_backup_file}"]
            unless -f $args{sql_backup_file};
        my $pt = path($args{sql_backup_file});
        my $basename = $pt->basename;
        if ($basename =~ /(.+)\.sql\z/i) {
            $sql_backup_dir = $1;
        } elsif ($basename =~ /(.+)\.sql\.gz\z/i) {
            $sql_backup_dir = $1;
            $decompress = 1;
        } else {
            return [412, "SQL backup file should be named *.sql or *.sql.gz: ".
                        "$args{sql_backup_file}"];
        }
        if (-d $sql_backup_dir) {
            log_info "SQL backup dir '$sql_backup_dir' already exists, ".
                "skipped extracting";
        } else {
            mkdir $sql_backup_dir, 0755
                or return [500, "Can't mkdir '$sql_backup_dir': $!"];
            $CWD = $sql_backup_dir;
            my @cmd;
            if ($decompress) {
                push @cmd, "zcat", $pt->absolute->stringify, "|";
            } else {
                push @cmd, "cat", $pt->absolute->stringify, "|";
            }
            push @cmd, "mysql-sql-dump-extract-tables",
                "--include-table-pattern", '^(tblclients|tblinvoices|tblinvoiceitems|tblorders)$';
            system({shell=>1, die=>1, log=>1}, @cmd);
        }
    } elsif ($args{sql_backup_dir}) {
        $sql_backup_dir = $args{sql_backup_dir};
        return [404, "No such dir: $sql_backup_dir"]
            unless -d $sql_backup_dir;
        $CWD = $sql_backup_dir;
    }

    my @sql;

    my $clientid = $args{client_id};
  FIND_CLIENT:
    {
        open my $fh, "<", "tblclients"
            or return [500, "Can't open $sql_backup_dir/tblclients: $!"];
        my $clientemail;
        $clientemail = lc $args{client_email} if defined $args{client_email};
        while (<$fh>) {
            next unless /^INSERT INTO `tblclients` \(`id`, `firstname`, `lastname`, `companyname`, `email`, [^)]+\) VALUES \((\d+),'(.*?)','(.*?)','(.*?)','(.*?)',/;
            my ($rid, $rfirstname, $rlastname, $rcompanyname, $remail) = ($1, $2, $3, $4, $5);
            if (defined $clientid) {
                # find by ID
                if ($rid == $clientid) {
                    $clientemail = $remail;
                    push @sql, $_;
                    log_info "Found client ID=%s in backup", $clientid;
                    last FIND_CLIENT;
                }
            } else {
                # find by email
                if (lc $remail eq $clientemail) {
                    $clientid = $rid;
                    push @sql, $_;
                    log_info "Found client email=%s in backup: ID=%s", $clientemail, $clientid;
                    last FIND_CLIENT;
                }
            }
        }
        return [404, "Couldn't find client email=$clientemail in database backup, please check the email or try another backup"];
    }

    my @invoiceids;
  FIND_INVOICES:
    {
        last unless $args{restore_invoices};
        open my $fh, "<", "tblinvoices"
            or return [500, "Can't open $sql_backup_dir/tblinvoices: $!"];
        while (<$fh>) {
            next unless /^INSERT INTO `tblinvoices` \(`id`, `userid`, [^)]+\) VALUES \((\d+),(\d+),/;
            my ($rid, $ruserid) = ($1, $2);
            if ($ruserid == $clientid) {
                push @invoiceids, $rid;
                push @sql, $_;
                log_info "Found client invoice in backup: ID=%s", $rid;
            }
        }
        log_info "Number of invoices found for client in backup: %d", ~~@invoiceids if @invoiceids;
    }

  FIND_INVOICEITEMS:
    {
        last unless @invoiceids;
        open my $fh, "<", "tblinvoiceitems"
            or return [500, "Can't open $sql_backup_dir/tblinvoiceitems: $!"];
        while (<$fh>) {
            next unless /^INSERT INTO `tblinvoiceitems` \(`id`, `invoiceid`, `userid`, [^)]+\) VALUES \((\d+),(\d+),(\d+)/;
            my ($rid, $rinvoiceid, $ruserid) = ($1, $2, $3);
            if (grep {$rinvoiceid == $_} @invoiceids) {
                log_trace "Adding invoice item %s for invoice #%s", $rid, $rinvoiceid;
                push @sql, $_;
            }
        }
    }

  FIND_HOSTINGS:
    {
        last unless $args{restore_hostings};
        open my $fh, "<", "tblhosting"
            or return [500, "Can't open $sql_backup_dir/tblhosting: $!"];
        while (<$fh>) {
            next unless /^INSERT INTO `tblhosting` \(`id`, `userid`, [^)]+\) VALUES \((\d+),(\d+),(\d+)/;
            my ($rid, $ruserid) = ($1, $2, $3);
            if ($ruserid == $clientid) {
                log_trace "Found hosting for client in backup: ID=%d", $rid;
                push @sql, $_;
            }
        }
    }

  FIND_DOMAINS:
    {
        last unless $args{restore_domains};
        open my $fh, "<", "tbldomains"
            or return [500, "Can't open $sql_backup_dir/tbldomains: $!"];
        while (<$fh>) {
            next unless /^INSERT INTO `tbldomains` \(`id`, `userid`, [^)]+\) VALUES \((\d+),(\d+),(\d+)/;
            my ($rid, $ruserid) = ($1, $2, $3);
            if ($ruserid == $clientid) {
                log_trace "Found domain for client in backup: ID=%d", $rid;
                push @sql, $_;
            }
        }
    }

    # TODO: tickets?

    # records in tblaccounts (transactions) are not deleted when client is deleted

    [200, "OK", \@sql];
}

1;
#ABSTRACT:

=head1 SEE ALSO

=cut
