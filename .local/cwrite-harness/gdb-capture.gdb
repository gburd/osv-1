# gdb-capture.gdb -- attach to the wedged OSv guest, enumerate threads, bank
# backtraces. Run: gdb -batch -x gdb-capture.gdb /mnt/nvme/osv-img/loader.elf
set pagination off
set print pretty on
set confirm off
python
import sys
sys.path.insert(0, '/mnt/nvme/osv/scripts')
end
# connect to the KVM gdb stub
target remote :1234
# load OSv gdb macros (osv info threads, etc.)
source /mnt/nvme/osv/scripts/loader.py
echo \n==================== OSV INFO THREADS ====================\n
osv info threads
echo \n==================== ALL THREAD BACKTRACES ====================\n
# For each OSv thread, switch and backtrace. osv info threads listing gives
# the switch mechanism; use "osv thread <id>" then bt.
python
import gdb
out = gdb.execute("osv info threads", to_string=True)
print(out)
end
echo \n==================== DONE ====================\n
