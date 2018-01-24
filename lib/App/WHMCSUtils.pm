package App::WHMCSUtils;

## no critic (InputOutput::RequireBriefOpen)

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

our %args_db = (
    db_name => {
        schema => 'str*',
        req => 1,
    },
    db_host => {
        schema => 'str*',
        default => 'localhost',
    },
    db_port => {
        schema => 'net::port*',
        default => '3306',
    },
    db_user => {
        schema => 'str*',
    },
    db_pass => {
        schema => 'str*',
    },
);

sub _connect_db {
    require DBIx::Connect::MySQL;

    my %args = @_;

    my $dsn = join(
        "",
        "DBI:mysql:database=$args{db_name}",
        (defined($args{db_host}) ? ";host=$args{db_host}" : ""),
        (defined($args{db_port}) ? ";port=$args{db_port}" : ""),
    );

    DBIx::Connect::MySQL->connect(
        $dsn, $args{db_user}, $args{db_pass},
        {RaiseError => 1},
    );
}

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

    # records in tblaccounts (transactions) are not deleted when client is
    # deleted

    [200, "OK", \@sql];
}

sub _add_monthly_revs {
    my ($row, $date1, $date2) = @_;

    if ($date2) {
        my ($y1, $m1) = $date1 =~ /\A(\d{4})-(\d{2})-(\d{2})/
            or die "Can't parse date1 '$date1'";
        my ($y2, $m2) = $date2 =~ /\A(\d{4})-(\d{2})-(\d{2})/
            or die "Can't parse date2 '$date2'";

        # first calculate how many months
        my ($y, $m) = ($y1, $m1);
        my $num_months = 0;
        while (1) {
            $num_months++;
            last if $y == $y2 && $m == $m2;
            $m++; if ($m == 13) { $m = 1; $y++ }
        }
        ($y, $m) = ($y1, $m1);
        $num_months-- unless $num_months < 2;
        while (1) {
            $row->{sprintf("rev_%04d_%02d", $y, $m)} =
                $row->{amount} / $num_months;
            last if $y == $y2 && $m == $m2;
            $m++; if ($m == 13) { $m = 1; $y++ }
        }
    } else {
        $date1 =~ /\A(\d{4})-(\d{2})-(\d{2})/
            or die "Can't parse date '$date1'";
        $row->{"rev_${1}_${2}"} = $row->{amount};
    }
}

$SPEC{calc_deferred_revenue} = {
    v => 1.1,
    description => <<'_',

Calculate revenue but split (defer) revenue for hosting over the course of
hosting period.

Recognizes English and Indonesian description text.

_
    args => {
        %args_db,
        date_start => {
            summary => 'Start from this date (based on invoice payment date)',
            schema => ['date*', 'x.perl.coerce_to' => 'DateTime'],
            tags => ['category:filtering'],
        },
        date_end => {
            summary => 'End at this date (based on invoice payment date)',
            schema => ['date*', 'x.perl.coerce_to' => 'DateTime'],
            tags => ['category:filtering'],
        },
    },
    features => {
        progress => 1,
    },
};
sub calc_deferred_revenue {
    my %args = @_;

    my $progress = $args{-progress};

    my $dbh = _connect_db(%args);

    my $extra_wheres = '';
    if ($args{date_start}) {
        $extra_wheres .= " AND i.datepaid >= '".$args{date_start}->ymd()."'";
    }
    if ($args{date_end}) {
        $extra_wheres .= " AND i.datepaid <= '".$args{date_end}->ymd()."'";
    }

    my $sth = $dbh->prepare(<<_);
SELECT

  ii.id id,
  ii.invoiceid invoiceid,
  ii.userid clientid,
  ii.type type,
  ii.relid relid,
  ii.description description,
  ii.amount amount,
  ii.taxed taxed,
  ii.duedate duedate,
  ii.notes notes,

  i.datepaid datepaid

FROM tblinvoiceitems ii
LEFT JOIN tblinvoices i ON ii.invoiceid=i.id
WHERE
  i.status='Paid' AND
  i.datepaid IS NOT NULL AND
  ii.amount <> 0 $extra_wheres
ORDER BY ii.invoiceid
_

    log_info "Loading all paid invoice items ...";
    $sth->execute;
    my @invoiceitems;
    while (my $row = $sth->fetchrow_hashref) {
        push @invoiceitems, $row;
    }
    log_info "Number of invoice items: %d", ~~@invoiceitems;

    my @rows;
    my $num_errors = 0;

    $progress->target(~~@invoiceitems);
  ITEM:
    for my $i (0..$#invoiceitems) {
        my $row = $invoiceitems[$i];
        my $label = "(".($i+1)."/".(scalar @invoiceitems).
            ") item#$row->{id} inv#=$row->{invoiceid} datepaid=#row->{datepaid} amount=$row->{amount} description='$row->{description}'";
        log_trace "Processing $label: %s ...", $row;
        $progress->update;

        if ($row->{type} eq 'AddFunds') {
            log_trace "$label: AddFunds is not a revenue, skipping this item";
            next ITEM;
        }

        my ($date1, $date2);
        if ($row->{description} =~ m!\((?<date1>(?<d1>\d{2})/(?<m1>\d{2})/(?<y1>\d{4})) - (?<date2>(?<d2>\d{2})/(?<m2>\d{2})/(?<y2>\d{4}))\)!) {
            my %m = %+;
          CHECK_DATE: {
                $m{d1} <= 31 or do { log_warn "$label: Day is >31 in date1 '$m{date1}', assuming immediate"; undef $date1; last CHECK_DATE };
                $m{m1} <= 12 or do { log_warn "$label: Month is >12 in date1 '$m{date1}', assuming immediate"; undef $date1; last CHECK_DATE };
                $m{d2} <= 31 or do { log_warn "$label: Day is >31 in date2 '$m{date1}', assuming immediate"; undef $date2; last CHECK_DATE };
                $m{m2} <= 12 or do { log_warn "$label: Month is >12 in date2 '$m{date2}', assuming immediate"; undef $date2; last CHECK_DATE };
                $date1 = "$m{y1}-$m{m1}-$m{d1}";
                $date2 = "$m{y2}-$m{m2}-$m{d2}";
                if ($date1 gt $date2) {
                    log_warn "$label: Date1 '$date1' > date2 '$date2' in description '$row->{description}', assuming immediate";
                    undef $date1; undef $date2;
                    last CHECK_DATE;
                }
                # sanity check
                if ($date1 lt '2008-01-01') {
                    log_warn "$label: Date1 '$date1' is too old, skipping this item";
                    next ITEM;
                }
                # sanity check
                if ($date2 lt '2008-01-01') {
                    log_warn "$label: Date2 '$date2' is too old, skipping this item";
                    next ITEM;
                }
            }
        }

        # sometimes invoices are created manually (type=''), so we have to infer
        # type from description
        my $type = $row->{type};
      INFER_TYPE: {
            last if $type;
            if ($row->{description} =~ /^(perpanjangan domain|domain renewal)/i && $date1 && $date2) {
                $type = 'Domain';
                last INFER_TYPE;
            }
            if ($row->{description} =~ /^(perpanjangan hosting|hosting renewal)/i && $date1 && $date2) {
                $type = 'Hosting';
                last INFER_TYPE;
            }
        }

      ITEM_HOSTING:
        {
            last unless $type eq 'Hosting' && $date1 && $date2;
            log_debug "$label: Item is hosting, deferring revenue $row->{amount} from $date1 to $date2";
            _add_monthly_revs($row, $date1, $date2);
            log_trace "row=%s", $row;
            push @rows, $row; next ITEM;
        }

        if ($type =~ /^(|Invoice|Item|Hosting|Addon|Domain|DomainRegister|DomainTransfer|PromoDomain|PromoHosting|Upgrade|MG_DIS_CHARGE)$/) {
            log_debug "$label: Type is '$type', recognized revenue $row->{amount} immediately (not deferred) at date of payment $row->{datepaid}";
            _add_monthly_revs($row, $row->{datepaid}, undef);
            push @rows, $row; next ITEM;
        }

        log_warn "$label: Can't categorize, assuming immediate";
        _add_monthly_revs($row, $row->{datepaid}, undef);
        push @rows, $row; next ITEM;
    }

    if ($num_errors) {
        return [500, "There are still errors in the invoice items, please fix first"];
    }

    my %revs; # key = period
    for my $row (@rows) {
        for my $k (keys %$row) {
            if ($k =~ /^rev_(\d{4})_(\d{2})$/) {
                $revs{"$1-$2"} += $row->{$k};
            } elsif ($k =~ /^rev_past$/) {
                $revs{past} = $row->{$k};
            }
        }
    }

    [200, "OK", \%revs];
}

1;
#ABSTRACT:

=head1 SEE ALSO

=cut
