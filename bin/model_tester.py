#!/usr/bin/python3
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel, PeftConfig

class ModelTester:
    def __init__(self, model_path):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        
        # Load the base model
        base_model_path = "Qwen/Qwen2-1.5B"
        base_model = AutoModelForCausalLM.from_pretrained(base_model_path, torch_dtype="auto")
        
        # Load the LoRA adapter
        peft_config = PeftConfig.from_pretrained(model_path)
        self.model = PeftModel.from_pretrained(base_model, model_path, torch_dtype="auto").to(self.device)
        
        # Load the tokenizer
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)

    def generate_response(self, command):
        prompt = f"Command: {command}\nOutput:"
        inputs = self.tokenizer(prompt, return_tensors="pt").to(self.device)
        
        print("Tokenized input:", self.tokenizer.convert_ids_to_tokens(inputs.input_ids[0]))
        
        with torch.no_grad():
            output = self.model.generate(
                **inputs,
                max_new_tokens=200,
                do_sample=True,
                temperature=0.7,
                pad_token_id=self.tokenizer.eos_token_id
            )

        response = self.tokenizer.decode(output[0], skip_special_tokens=False)
        
        print("Tokenized output:", self.tokenizer.convert_ids_to_tokens(output[0]))
        
        # Extract only the output part
        output_start = response.find("Output:")
        if output_start != -1:
            response = response[output_start + 7:].strip()
        return response

    def check_output_format(self, output):
        format_checks = {
            "Non-empty response": len(output) > 0,
            "No 'Command:' in output": "Command:" not in output,
            "Single line response": output.count('\n') <= 1,
            "Excessive repetition": len(set(output.split())) / len(output.split()) < 0.5 if output.split() else False
        }
        
        return format_checks

    def run_test(self, command):
        print(f"Command: {command}")
        response = self.generate_response(command)
        print(f"Response: {response}")
        format_checks = self.check_output_format(response)
        print("Format checks:")
        for check, result in format_checks.items():
            print(f"  {check}: {'Passed' if result else 'Failed'}")
        print("\n")

def test_base_model():
    base_model_path = "Qwen/Qwen2-1.5B"
    model = AutoModelForCausalLM.from_pretrained(base_model_path, torch_dtype="auto").to("cuda" if torch.cuda.is_available() else "cpu")
    tokenizer = AutoTokenizer.from_pretrained(base_model_path)
    
    command = "ls /home"
    prompt = f"Command: {command}\nOutput:"
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    
    with torch.no_grad():
        output = model.generate(
            **inputs,
            max_new_tokens=200,
            do_sample=True,
            temperature=0.7,
            pad_token_id=tokenizer.eos_token_id
        )
    
    response = tokenizer.decode(output[0], skip_special_tokens=False)
    print("Base Model Response:", response)

if __name__ == "__main__":
    model_path = "../test_checkpoint"
    tester = ModelTester(model_path)
    
    test_commands = [
        "ls /home",
        "cd /etc",
        "cat /etc/passwd",
        "echo $HOME",
        "whoami"
    ]
    
    for command in test_commands:
        tester.run_test(command)
    
    print("Testing base model without fine-tuning:")
    test_base_model()
