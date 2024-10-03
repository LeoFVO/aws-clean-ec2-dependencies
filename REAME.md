# Cleaning EC2 unused resources

## Getting started

### List resources

List all AMIs and snapshots from AWS account older than 1 year on eu-west-1

```bash
./manage.sh amis list 1y --region eu-west-1 
./manage.sh snapshots list 1y --region eu-west-1 
```

List all AMIs and snapshots from AWS account older than 1 year on all-regions

```bash
./manage.sh amis list 1y --all-region
./manage.sh snapshots list 1y --all-region
```

## Clean ressources

List all AMIs and snapshots from AWS account older than 1 year on eu-west-1

```bash
./manage.sh amis delete --region eu-west-1 
./manage.sh snapshots delete --region eu-west-1 
```
