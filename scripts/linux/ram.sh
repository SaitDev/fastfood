#!/bin/sh

# Show system-wide memory usage and the largest process groups. PSS is used
# instead of RSS so shared pages are divided proportionally between processes.

process_limit=${1:-10}
case $process_limit in
    0 | *[!0-9]*)
        printf 'Usage: %s [positive-process-count]\n' "$0" >&2
        exit 2
        ;;
esac

process_stats=$(mktemp) || exit 1
trap 'rm -f "$process_stats"' EXIT
trap 'exit 1' HUP INT TERM

processes_seen=0
processes_read=0
for p in /proc/[0-9]*; do
    processes_seen=$((processes_seen + 1))
    name=$(cat "$p/comm" 2>/dev/null) || continue
    stats=$(
        awk '
            /^Pss:/     { pss = $2; have_pss = 1 }
            /^Swap:/    { swap = $2 }
            /^SwapPss:/ { swap_pss = $2 }
            END {
                if (!have_pss)
                    exit 1
                # SwapPss avoids double-counting shared swapped pages. Fall
                # back to Swap on kernels that do not expose SwapPss.
                if (swap_pss == "")
                    swap_pss = swap
                printf "%d\t%d\n", pss, swap_pss
            }
        ' "$p/smaps_rollup" 2>/dev/null
    ) || continue

    printf '%s\t%s\n' "$stats" "$name"
    processes_read=$((processes_read + 1))
done >"$process_stats"

awk -v processes_read="$processes_read" -v processes_seen="$processes_seen" '
    function human(kib) {
        if (kib >= 1048576)
            return sprintf("%.1f GiB", kib / 1048576)
        return sprintf("%.1f MiB", kib / 1024)
    }

    function percent(part, whole) {
        if (whole == 0)
            return "0.0%"
        return sprintf("%.1f%%", part * 100 / whole)
    }

    FNR == NR {
        if ($1 ~ /^(MemTotal|MemAvailable|SwapTotal|SwapFree):$/)
            value[$1] = $2
        next
    }

    { process_ram += $1; process_swap += $2 }

    END {
        system_ram_used = value["MemTotal:"] - value["MemAvailable:"]
        system_swap_used = value["SwapTotal:"] - value["SwapFree:"]

        print "System memory:"
        printf "  RAM:  %s used / %s total (%s available)\n", \
            human(system_ram_used), human(value["MemTotal:"]), \
            human(value["MemAvailable:"])
        printf "  Swap: %s used / %s total\n", \
            human(system_swap_used), human(value["SwapTotal:"])

        print "\nProcess memory inspected:"
        printf "  PIDs with PSS: %d of %d scanned\n", \
            processes_read, processes_seen
        printf "  RAM PSS:  %s (%s of system-used RAM)\n", \
            human(process_ram), percent(process_ram, system_ram_used)
        printf "  Swap PSS: %s (%s of system-used swap)\n", \
            human(process_swap), percent(process_swap, system_swap_used)
        printf "  Combined RAM + swap PSS: %s\n", \
            human(process_ram + process_swap)
        printf "  Outside process PSS (RAM / swap): %s / %s\n", \
            human(system_ram_used - process_ram), \
            human(system_swap_used - process_swap)
    }
' /proc/meminfo "$process_stats"

printf '\nTop %s process names by RAM + swap PSS:\n' "$process_limit"
printf '%10s %10s %10s  %s\n' 'TOTAL MiB' 'RAM MiB' 'SWAP MiB' 'PROCESS'

tab=$(printf '\t')
awk -F '\t' '
    {
        ram[$3] += $1
        swap[$3] += $2
    }
    END {
        for (name in ram)
            printf "%d\t%d\t%d\t%s\n", \
                ram[name] + swap[name], ram[name], swap[name], name
    }
' "$process_stats" |
    sort -t "$tab" -k1,1nr |
    head -n "$process_limit" |
    awk -F '\t' '{ printf "%10.1f %10.1f %10.1f  %s\n", $1/1024, $2/1024, $3/1024, $4 }'
