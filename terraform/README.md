# Provision the benchmark box (c7i.2xlarge)

Spins up one Amazon Linux 2023 `c7i.2xlarge` in `us-east-1` (matching
turbopuffer's published environment), with a generated SSH key and SSH locked
to your current public IP. Destroy it the moment you're done — it bills hourly
(~$0.36/hr on-demand).

## Prereqs
- Terraform ≥ 1.5
- AWS credentials in your shell (`aws configure`, or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_PROFILE`)
- A default VPC in `us-east-1` (standard on most accounts)

## 1. Provision

```bash
cd terraform
terraform init
terraform apply        # review, type yes
```
Outputs an `ssh` command and the public IP. The private key is written to
`terraform/sbg-bench-key.pem` (git-ignored, chmod 400).

## 2. Run the benchmark on the box

```bash
$(terraform output -raw ssh)          # SSH in

# get the code (public repo):
git clone https://github.com/infino-ai/search-benchmark-game.git
cd search-benchmark-game
# (private? use a GitHub PAT: git clone https://<TOKEN>@github.com/infino-ai/search-benchmark-game.git)

scripts/setup-aws.sh                   # Rust 1.89 + Temurin 21 + deps
source "$HOME/.cargo/env"
export JAVA_HOME="$HOME/jdk-21.0.8+9" && export PATH="$PATH:$JAVA_HOME/bin"

scripts/run-bench.sh                   # corpus + compile + index + bench + merge
# => writes ~/search-benchmark-game/results.json
```

## 3. Pull results back to your laptop & publish

From your laptop, in your local clone:
```bash
scp -i terraform/sbg-bench-key.pem \
  ec2-user@$(cd terraform && terraform output -raw public_ip):~/search-benchmark-game/results.json \
  ./results.json
git add results.json && git commit -m "bench: $(date -u +%F) run" && git push
```
The Pages workflow publishes it automatically.

## 4. Destroy (do this when done!)

```bash
cd terraform
terraform destroy      # type yes
```
This removes the instance, security group, key pair, and EBS volume. Billing
stops. The local `.pem` is left behind; delete it if you like.

## Knobs
- `terraform apply -var ssh_cidr=1.2.3.4/32` to pin SSH manually.
- `terraform apply -var instance_type=c7i.4xlarge` for a bigger box.
- `terraform apply -var volume_size_gb=200` for more disk.
