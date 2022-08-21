echo "What do you want the swapfile to be named?"
read swapfile
echo "How many gigabytes do you want the swap to be?"
read gbs
echo "Are you sure?, if not, please cntrl + c right now!"

sudo fallocate -l $gbsG /$swapfile
sudo chmod 600 /$swapfile
sudo mkswap /$swapfile
sudo swapon /$swapfile
echo '/$swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

echo "DONE"
echo "DONE"
echo "DONE"
