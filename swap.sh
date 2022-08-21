echo "What do you want the swapfile to be named?"
read swapfile
echo "How many gigabytes do you want the swap to be? MAKE SURE TO ADD A G AFTER IT!!!"
read gbs

fallocate -l $gbs /$swapfile
chmod 600 /$swapfile
mkswap /$swapfile
swapon /$swapfile
echo '/$swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

echo "DONE"
echo "DONE"
echo "DONE"
