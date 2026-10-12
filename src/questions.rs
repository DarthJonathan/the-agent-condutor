//! Human clarification requests shared by every headless provider.
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    #[serde(default)]
    pub id: String,
    pub label: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserQuestion {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub header: String,
    pub question: String,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
    #[serde(default, alias = "multiSelect")]
    pub multi_select: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionAnswer {
    pub question_id: String,
    #[serde(default)]
    pub option_ids: Vec<String>,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub skipped: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionRequest {
    pub id: Uuid,
    pub questions: Vec<UserQuestion>,
    pub answers: Option<Vec<QuestionAnswer>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered_by: Option<Uuid>,
}

impl QuestionRequest {
    pub fn from_value(value: &serde_json::Value) -> Result<Self> {
        #[derive(Deserialize)]
        struct Input {
            questions: Vec<UserQuestion>,
        }
        let mut input: Input = serde_json::from_value(value.clone())?;
        if input.questions.is_empty() || input.questions.len() > 4 {
            bail!("Ask one to four questions at a time.");
        }
        for (i, question) in input.questions.iter_mut().enumerate() {
            question.id = format!("q{}", i + 1);
            question.question = question.question.trim().into();
            if question.question.is_empty()
                || question.question.len() > 4096
                || question.header.len() > 64
                || question.options.len() > 8
            {
                bail!("Question text or choices exceed the supported limits.");
            }
            let mut labels = std::collections::HashSet::new();
            for (j, option) in question.options.iter_mut().enumerate() {
                option.id = format!("o{}", j + 1);
                option.label = option.label.trim().into();
                if option.label.is_empty()
                    || option.label.len() > 256
                    || option.description.len() > 2048
                    || !labels.insert(option.label.clone())
                {
                    bail!("Use distinct, non-empty choice labels below 256 bytes.");
                }
            }
        }
        Ok(Self {
            id: Uuid::new_v4(),
            questions: input.questions,
            answers: None,
            answered_by: None,
        })
    }

    pub fn validate_answers(&self, answers: &[QuestionAnswer]) -> Result<Vec<QuestionAnswer>> {
        if self.answers.is_some() {
            bail!("These questions have already been answered.");
        }
        if answers.len() != self.questions.len() {
            bail!("Answer or skip each question.");
        }
        let mut normalized = Vec::new();
        let mut bytes = 0;
        for question in &self.questions {
            let matching: Vec<_> = answers
                .iter()
                .filter(|a| a.question_id == question.id)
                .collect();
            if matching.len() != 1 {
                bail!("Answer each question exactly once.");
            }
            let mut answer = matching[0].clone();
            answer.text = answer.text.trim().into();
            bytes += answer.text.len();
            if bytes > 16 * 1024 {
                bail!("Keep your answers below 16 KiB.");
            }
            let mut seen = std::collections::HashSet::new();
            if answer
                .option_ids
                .iter()
                .any(|id| !seen.insert(id) || !question.options.iter().any(|o| &o.id == id))
                || (!question.multi_select && answer.option_ids.len() > 1)
            {
                bail!("Choose valid options for each question.");
            }
            if answer.skipped {
                if !answer.option_ids.is_empty() || !answer.text.is_empty() {
                    bail!("A skipped question cannot include an answer.");
                }
            } else if answer.option_ids.is_empty() && answer.text.is_empty() {
                bail!("Choose an option, write an answer, or skip the question.");
            }
            // Preserve the agent's option order, independent of the order of clicks.
            answer.option_ids = question
                .options
                .iter()
                .filter(|o| answer.option_ids.contains(&o.id))
                .map(|o| o.id.clone())
                .collect();
            normalized.push(answer);
        }
        Ok(normalized)
    }

    pub fn answer_text(&self, answers: &[QuestionAnswer]) -> String {
        self.answer_text_from(answers, None)
    }

    pub fn answer_text_from(&self, answers: &[QuestionAnswer], coworker: Option<&str>) -> String {
        let mut text = String::from("Answers to your questions:\n");
        for question in &self.questions {
            let Some(answer) = answers.iter().find(|a| a.question_id == question.id) else {
                text.push_str(&format!("\n{}\nAwaiting an answer.\n", question.question));
                continue;
            };
            text.push_str(&format!("\n{}\n", question.question));
            if answer.skipped {
                text.push_str(&format!("Skipped by {}. Continue with your best judgment; do not repeat this question.\n", coworker.unwrap_or("the user")));
            } else {
                for option in question
                    .options
                    .iter()
                    .filter(|o| answer.option_ids.contains(&o.id))
                {
                    text.push_str(&format!("Selected: {}\n", option.label));
                }
                if !answer.text.is_empty() {
                    text.push_str(&format!(
                        "{} answer: {}\n",
                        coworker.unwrap_or("User"),
                        answer.text
                    ));
                }
            }
        }
        text
    }

    pub fn envelope(&self) -> String {
        format!(
            "\n<conductor-ask>\n{}\n</conductor-ask>\n",
            serde_json::json!({"questions": self.questions})
        )
    }

    pub fn markdown(&self) -> String {
        let mut text = String::new();
        for question in &self.questions {
            text.push_str(&format!("\n**{}**\n\n", question.question));
            for option in &question.options {
                text.push_str(&format!(
                    "- {}{}\n",
                    option.label,
                    if option.description.is_empty() {
                        String::new()
                    } else {
                        format!(": {}", option.description)
                    }
                ));
            }
        }
        if let Some(answers) = &self.answers {
            text.push_str(&self.answer_text_from(answers, self.answered_by.map(|_| "Teammate")));
        } else {
            text.push_str("\n*Waiting for your answer.*\n");
        }
        text
    }
}

/// Only an explicit, unfenced envelope for this request can resolve its choices.
pub fn extract_answers(
    output: &str,
    request: &QuestionRequest,
) -> Result<(String, Vec<QuestionAnswer>)> {
    #[derive(Deserialize)]
    struct Reply {
        request_id: Uuid,
        answers: Vec<QuestionAnswer>,
    }
    let mut remaining = output;
    let mut visible = String::new();
    let mut fenced = false;
    let mut answers = None;
    while !remaining.is_empty() {
        let end = remaining.find('\n').map_or(remaining.len(), |i| i + 1);
        let line = &remaining[..end];
        if line.trim_start().starts_with("```") || line.trim_start().starts_with("~~~") {
            fenced = !fenced;
        }
        if !fenced && line.trim() == "<conductor-answer>" {
            if answers.is_some() {
                bail!("Return one answer envelope for the delegated questions.");
            }
            let close = remaining[end..]
                .find("</conductor-answer>")
                .ok_or_else(|| anyhow::anyhow!("The teammate's answer envelope was incomplete."))?;
            let body = &remaining[end..end + close];
            let tail = &remaining[end + close..];
            let close_end = tail.find('\n').map_or(tail.len(), |i| i + 1);
            if body.len() > 64 * 1024
                || !body.ends_with('\n')
                || tail[..close_end].trim() != "</conductor-answer>"
            {
                bail!("Use a complete answer envelope on its own lines, below 64 KiB.");
            }
            let reply: Reply = serde_json::from_str(body)?;
            if reply.request_id != request.id {
                bail!("The teammate answered a different question request.");
            }
            answers = Some(request.validate_answers(&reply.answers)?);
            remaining = &tail[close_end..];
            continue;
        }
        visible.push_str(line);
        remaining = &remaining[end..];
    }
    Ok((
        visible.trim().into(),
        answers.ok_or_else(|| {
            anyhow::anyhow!(
                "The teammate did not return structured answers. The questions remain open."
            )
        })?,
    ))
}

/// Explicit own-line envelopes only. Examples, quotes, malformed JSON and partial blocks stay text.
pub fn extract(output: &str) -> (String, Option<QuestionRequest>) {
    let mut visible = String::new();
    let mut remaining = output;
    let mut fenced = false;
    let mut request = None;
    while !remaining.is_empty() {
        let line_end = remaining.find('\n').map_or(remaining.len(), |i| i + 1);
        let line = &remaining[..line_end];
        if line.trim_start().starts_with("```") || line.trim_start().starts_with("~~~") {
            fenced = !fenced;
        }
        if !fenced
            && request.is_none()
            && line.trim() == "<conductor-ask>"
            && let Some(end) = remaining[line_end..].find("</conductor-ask>")
        {
            let body = &remaining[line_end..line_end + end];
            let tail = &remaining[line_end + end..];
            let close_end = tail.find('\n').map_or(tail.len(), |i| i + 1);
            if body.len() <= 64 * 1024
                && tail[..close_end].trim() == "</conductor-ask>"
                && (body.ends_with('\n') || body.ends_with('\r'))
                && let Ok(value) = serde_json::from_str(body)
                && let Ok(parsed) = QuestionRequest::from_value(&value)
            {
                request = Some(parsed);
                remaining = &tail[close_end..];
                continue;
            }
        }
        visible.push_str(line);
        remaining = &remaining[line_end..];
    }
    (visible.trim().into(), request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn example() -> QuestionRequest {
        QuestionRequest::from_value(&json!({"questions":[
            {"question":"Which scope?", "header":"Scope", "options":[{"label":"Small"},{"label":"Full"}]},
            {"question":"Which platforms?", "options":[{"label":"Mac"},{"label":"Linux"}], "multiSelect":true},
            {"question":"Any other constraints?"}
        ]})).unwrap()
    }

    #[test]
    fn envelopes_are_explicit_and_validated() {
        let envelope = example().envelope();
        let (visible, request) = extract(&format!("Please choose.\n{envelope}"));
        assert_eq!(visible, "Please choose.");
        assert!(request.unwrap().questions[1].multi_select);
        for sample in [
            format!("```json\n{envelope}\n```"),
            format!("> {}", envelope.trim()),
            format!("Example: {}", envelope.trim()),
            "<conductor-ask>\n{\"questions\":[]}\n</conductor-ask>".into(),
            "<conductor-ask>\n{}".into(),
        ] {
            let (visible, request) = extract(&sample);
            assert!(request.is_none());
            assert_eq!(visible, sample.trim());
        }
    }

    #[test]
    fn answers_validate_options_free_text_skips_and_duplicates() {
        let request = example();
        let answers = vec![
            QuestionAnswer {
                question_id: "q1".into(),
                option_ids: vec!["o1".into()],
                text: String::new(),
                skipped: false,
            },
            QuestionAnswer {
                question_id: "q2".into(),
                option_ids: vec!["o2".into(), "o1".into()],
                text: "also Windows @codex".into(),
                skipped: false,
            },
            QuestionAnswer {
                question_id: "q3".into(),
                option_ids: vec![],
                text: String::new(),
                skipped: true,
            },
        ];
        let normalized = request.validate_answers(&answers).unwrap();
        assert_eq!(normalized[1].option_ids, ["o1", "o2"]);
        assert!(request.answer_text(&normalized).contains("Selected: Small"));
        let mut invalid = answers.clone();
        invalid[0].option_ids.push("o2".into());
        assert!(request.validate_answers(&invalid).is_err());
        invalid = answers.clone();
        invalid[0].option_ids = vec!["unknown".into()];
        assert!(request.validate_answers(&invalid).is_err());
        invalid = answers.clone();
        invalid[2].question_id = "q2".into();
        assert!(request.validate_answers(&invalid).is_err());
        invalid = answers.clone();
        invalid[0].option_ids.clear();
        invalid[0].text = "  Custom scope  ".into();
        assert_eq!(
            request.validate_answers(&invalid).unwrap()[0].text,
            "Custom scope"
        );
        let mut answered = request;
        answered.answers = Some(answers.clone());
        assert!(answered.validate_answers(&answers).is_err());
    }

    #[test]
    fn teammate_envelopes_are_scoped_and_validate_every_answer() {
        let request = example();
        let value = json!({"request_id":request.id,"answers":[
            {"question_id":"q1","option_ids":["o1"]},
            {"question_id":"q2","option_ids":["o2","o1"],"text":"Verified against the workspace"},
            {"question_id":"q3","skipped":true}
        ]});
        let envelope = format!("<conductor-answer>\n{value}\n</conductor-answer>");
        let (text, answers) =
            extract_answers(&format!("My findings.\n{envelope}"), &request).unwrap();
        assert_eq!(text, "My findings.");
        assert_eq!(answers[1].option_ids, ["o1", "o2"]);
        for output in [
            format!("```json\n{envelope}\n```"),
            format!("Example: {envelope}"),
            format!("{envelope}\n{envelope}"),
            "<conductor-answer>\n{}".into(),
        ] {
            assert!(extract_answers(&output, &request).is_err());
        }
        for mutation in [
            "wrong_request",
            "invalid_option",
            "missing_answer",
            "duplicate_answer",
        ] {
            let mut wrong = value.clone();
            match mutation {
                "wrong_request" => wrong["request_id"] = json!(Uuid::new_v4()),
                "invalid_option" => wrong["answers"][0]["option_ids"] = json!(["unknown"]),
                "missing_answer" => {
                    wrong["answers"].as_array_mut().unwrap().pop();
                }
                _ => wrong["answers"][1]["question_id"] = json!("q1"),
            }
            assert!(
                extract_answers(
                    &format!("<conductor-answer>\n{wrong}\n</conductor-answer>"),
                    &request
                )
                .is_err()
            );
        }
        assert!(request.answers.is_none());
    }
}
