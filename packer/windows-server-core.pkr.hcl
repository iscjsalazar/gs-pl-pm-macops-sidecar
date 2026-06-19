packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_path" {
  type = string
}
variable "winpass" {
  type      = string
  sensitive = true
}
variable "output_dir" {
  type    = string
  default = "output-pm-win2022core"
}
variable "cpus" {
  type    = number
  default = 4
}
variable "memory" {
  type    = number
  default = 6144
}
variable "disk_size" {
  type    = number
  default = 61440
}

source "vmware-iso" "win2022core" {
  iso_url      = var.iso_path
  iso_checksum = "none"

  guest_os_type        = "windows9srv-64"
  version              = "20"
  firmware             = "efi"
  cpus                 = var.cpus
  memory               = var.memory
  disk_size            = var.disk_size
  disk_adapter_type    = "nvme"
  network_adapter_type = "e1000e"

  # Autounattend.xml (generado por build-vm.sh con la password) en un CD secundario.
  cd_files = ["./Autounattend.xml"]
  cd_label = "PROVISION"

  headless     = true
  boot_wait    = "1s"
  # Atrapar "Press any key to boot from CD or DVD" (UEFI): varias pulsaciones cubriendo la ventana.
  boot_command = ["<wait2><enter><wait2><enter><wait2><enter>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.winpass
  winrm_timeout  = "60m"

  shutdown_command = "shutdown /s /t 5 /f /d p:4:1 /c \"packer\""
  shutdown_timeout = "20m"

  output_directory = var.output_dir
  vm_name          = "pm-win2022core"
  # NAT y VNC (para inyectar boot_command) son defaults de Packer; no los sobreescribimos.
}

build {
  sources = ["source.vmware-iso.win2022core"]

  provisioner "powershell" {
    scripts = ["./provision/01-openssh.ps1"]
  }
}
