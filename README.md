# tf-gcp-shenanigans

```shell
terraform plan -input=false -var 'project=ofrolovs-sandbox' -out tfplan
```

```shell
terraform plan -input=false -var 'project=ofrolovs-sandbox' -destroy -out tfplan
```

```shell
terraform apply tfplan
```

```shell
terraform graph > shenanigans-X.dot
```

```shell
terraform graph -plan=tfplan > shenanigans-X.dot
```
