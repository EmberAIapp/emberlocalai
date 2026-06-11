/// MIL (Model Intermediate Language) builder for ANE kernels
/// Provides a safe, builder-pattern API for generating MIL programs

pub struct MilProgram {
    name: String,
    operations: Vec<MilOp>,
    inputs: Vec<MilTensor>,
    outputs: Vec<String>,
}

pub struct MilTensor {
    pub name: String,
    pub dtype: String,
    pub shape: Vec<usize>,
}

pub enum MilOp {
    Cast { input: String, output: String, dtype: String },
    Conv { input: String, weight_name: String, output: String, out_channels: usize, in_channels: usize },
    Add { a: String, b: String, output: String },
    Mul { input: String, scalar: f32, output: String },
    Concat { inputs: Vec<String>, output: String, axis: usize },
}

impl MilProgram {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            operations: Vec::new(),
            inputs: Vec::new(),
            outputs: Vec::new(),
        }
    }

    pub fn add_input(mut self, name: &str, shape: Vec<usize>, dtype: &str) -> Self {
        self.inputs.push(MilTensor {
            name: name.to_string(),
            dtype: dtype.to_string(),
            shape,
        });
        self
    }

    pub fn cast(mut self, input: &str, output: &str, dtype: &str) -> Self {
        self.operations.push(MilOp::Cast {
            input: input.to_string(),
            output: output.to_string(),
            dtype: dtype.to_string(),
        });
        self
    }

    pub fn conv(mut self, input: &str, weight_name: &str, output: &str, out_ch: usize, in_ch: usize) -> Self {
        self.operations.push(MilOp::Conv {
            input: input.to_string(),
            weight_name: weight_name.to_string(),
            output: output.to_string(),
            out_channels: out_ch,
            in_channels: in_ch,
        });
        self
    }

    pub fn add(mut self, a: &str, b: &str, output: &str) -> Self {
        self.operations.push(MilOp::Add {
            a: a.to_string(),
            b: b.to_string(),
            output: output.to_string(),
        });
        self
    }

    pub fn mul_scalar(mut self, input: &str, scalar: f32, output: &str) -> Self {
        self.operations.push(MilOp::Mul {
            input: input.to_string(),
            scalar,
            output: output.to_string(),
        });
        self
    }

    pub fn set_output(mut self, name: &str) -> Self {
        self.outputs.push(name.to_string());
        self
    }

    /// Generate MIL source text
    pub fn build(&self) -> String {
        let mut mil = format!("program(\"{}\")\n{{\n", self.name);

        // Function signature
        mil.push_str("    func main(\n");
        for (i, input) in self.inputs.iter().enumerate() {
            let shape_str: Vec<String> = input.shape.iter().map(|s| s.to_string()).collect();
            mil.push_str(&format!(
                "        {}: tensor<{}, [{}]>",
                input.name, input.dtype, shape_str.join(", ")
            ));
            if i < self.inputs.len() - 1 { mil.push(','); }
            mil.push('\n');
        }

        // Output type from last output
        mil.push_str("    ) {\n");

        // Operations
        for op in &self.operations {
            match op {
                MilOp::Cast { input, output, dtype } => {
                    mil.push_str(&format!(
                        "        let {output} = cast(x={input}, dtype=\"{dtype}\");\n"
                    ));
                }
                MilOp::Conv { input, weight_name, output, out_channels, in_channels } => {
                    mil.push_str(&format!(
                        "        let {output} = conv(\n            x={input},\n            weight=weights(\"{weight_name}\", [{out_channels}, {in_channels}, 1, 1], \"fp16\"),\n            strides=[1, 1], pad_type=\"valid\", dilations=[1, 1]\n        );\n"
                    ));
                }
                MilOp::Add { a, b, output } => {
                    mil.push_str(&format!(
                        "        let {output} = add(x={a}, y={b});\n"
                    ));
                }
                MilOp::Mul { input, scalar, output } => {
                    mil.push_str(&format!(
                        "        let {output} = mul(x={input}, y=const({scalar}));\n"
                    ));
                }
                MilOp::Concat { inputs, output, axis } => {
                    let inputs_str = inputs.join(", ");
                    mil.push_str(&format!(
                        "        let {output} = concat(values=[{inputs_str}], axis={axis});\n"
                    ));
                }
            }
        }

        // Return
        if let Some(out) = self.outputs.first() {
            mil.push_str(&format!("        return {out};\n"));
        }

        mil.push_str("    }\n}\n");
        mil
    }
}
