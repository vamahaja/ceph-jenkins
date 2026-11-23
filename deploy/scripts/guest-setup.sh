# Jenkins user, password SSH, and /home/jenkins disk. Helm inserts this into
# each cloud-init script. __SSH_PUBLIC_KEY__ is replaced at render time.
systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh
if getent passwd 1000 >/dev/null; then
  existing="$(getent passwd 1000 | cut -d: -f1)"
  if [ "${existing}" != "jenkins" ]; then
    usermod -l jenkins -d /home/jenkins -m "${existing}"
  fi
else
  groupadd -g 1000 jenkins || true
  useradd -u 1000 -g 1000 -m -s /bin/bash jenkins
fi
groupmod -n jenkins "$(id -gn jenkins)" 2>/dev/null || true
usermod -u 1000 -g 1000 -s /bin/bash jenkins
getent group mock >/dev/null && usermod -a -G mock jenkins || true
# Rootless podman maps image UIDs through these ranges. Without them, pulling
# a bootstrap image fails on files such as /var/spool/mail (gid 12).
grep -q '^jenkins:' /etc/subuid || usermod --add-subuids 100000-165535 jenkins
grep -q '^jenkins:' /etc/subgid || usermod --add-subgids 100000-165535 jenkins
echo "jenkins ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/jenkins
chmod 440 /etc/sudoers.d/jenkins
echo 'jenkins:jenkins' | chpasswd
mkdir -p /etc/ssh/sshd_config.d
printf '%s\n' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/00-jenkins-password.conf
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
home_disk=""
for _ in $(seq 1 30); do
  if [ -b /dev/disk/by-id/virtio-homedisk ]; then
    home_disk=/dev/disk/by-id/virtio-homedisk
    break
  fi
  sleep 2
done
if [ -z "$home_disk" ]; then
  echo "jenkins home disk /dev/disk/by-id/virtio-homedisk not found" >&2
  exit 1
fi
if ! blkid "$home_disk" >/dev/null 2>&1; then
  mkfs.ext4 -F -L jenkins-home "$home_disk"
fi
mkdir -p /home/jenkins
if ! mountpoint -q /home/jenkins; then
  mount "$home_disk" /home/jenkins
fi
home_uuid="$(blkid -s UUID -o value "$home_disk")"
if ! grep -q "$home_uuid" /etc/fstab; then
  echo "UUID=${home_uuid} /home/jenkins ext4 defaults,nofail 0 2" >> /etc/fstab
fi
chown jenkins:jenkins /home/jenkins
chmod 755 /home/jenkins
install -d -m 700 -o jenkins -g jenkins /home/jenkins/.ssh
echo '__SSH_PUBLIC_KEY__' > /home/jenkins/.ssh/authorized_keys
chown jenkins:jenkins /home/jenkins/.ssh/authorized_keys
chmod 600 /home/jenkins/.ssh/authorized_keys
