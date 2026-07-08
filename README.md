# Linux Server Automation Toolkit

The Linux Server Automation Toolkit is a Bash-based project designed to
simplify and automate common Linux system administration tasks. Instead of
manually executing multiple commands, this toolkit provides an interactive
menu that allows users to perform essential server management operations
quickly and efficiently.

The toolkit automates tasks such as updating and upgrading the operating
system, installing developer tools, Docker, Nginx, and AWS CLI, configuring
the firewall, enabling SSH, creating developer users, checking system health,
and generating detailed system reports. These features help reduce repetitive
manual work and improve productivity.

The project follows a modular architecture, where each administrative task is
implemented as a separate Bash script. This design makes the toolkit easy to
maintain, extend, and customize without affecting the rest of the project.

This project was developed to strengthen practical Linux system administration
and Bash scripting skills while demonstrating automation techniques commonly
used in real-world server environments. It serves as both a learning resource
and a foundation for building more advanced DevOps and infrastructure
automation projects.

## Features

- Interactive menu-driven interface
- Update and upgrade Linux packages
- Install Docker
- Install Nginx
- Install AWS CLI
- Install Developer Tools
- Configure UFW Firewall
- Enable SSH service
- Create Developer Users
- Monitor System Health
- Generate System Reports
- Modular Bash script architecture
- Comprehensive logging and reporting

* ## Project Structure

```
Linux-Server-Automation/
│
├── lib/                 # Common utility libraries
│   ├── colors.sh
│   ├── logger.sh
│   ├── utils.sh
│   └── validators.sh
│
├── modules/             # Individual automation modules
│   ├── update_system.sh
│   ├── upgrade_packages.sh
│   ├── install_docker.sh
│   ├── install_nginx.sh
│   ├── install_awscli.sh
│   ├── install_devtools.sh
│   ├── configure_firewall.sh
│   ├── enable_ssh.sh
│   ├── create_developer_user.sh
│   ├── check_system_health.sh
│   ├── generate_report.sh
│   └── menu.sh
│
├── logs/                # Log files
├── reports/             # Generated reports
├── setup.sh             # Main entry point
└── README.md
```

## Installation

### Clone the repository

```bash
git clone https://github.com/Rohithastro/Linux-Server-Automation.git
```

### Navigate to the project directory

```bash
cd Linux-Server-Automation
```

### Make the main script executable

```bash
chmod +x setup.sh
```

### Run the toolkit

```bash
./setup.sh
```

## Usage

1. Launch the toolkit by running:

```bash
./setup.sh
```

2. Select the desired operation from the interactive menu.

3. Follow the on-screen instructions to complete the selected task.

4. Generated logs are stored in the `logs/` directory.

5. Generated reports are stored in the `reports/` directory.

## Technologies Used

- Bash Shell Scripting
- Linux (Ubuntu)
- Git
- GitHub
- UFW Firewall
- OpenSSH
- Docker
- Nginx
- AWS CLI
