//! Inbox dismissal acknowledges a notification, never its question or approval.
use crate::{model::Run, team::Attention};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Key {
    pub id: Uuid,
    pub revision: Uuid,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Dismissal {
    pub run_id: Uuid,
    #[serde(flatten)]
    pub key: Key,
}

#[derive(Serialize)]
pub struct Item {
    #[serde(flatten)]
    pub key: Key,
    pub message_id: Option<Uuid>,
    pub owner_id: Option<Uuid>,
    pub kind: &'static str,
    pub title: String,
}

fn pending(run: &Run) -> Vec<Item> {
    let Some(chat) = &run.conversation else {
        return vec![];
    };
    let mut items = vec![];
    for message in &chat.messages {
        if let Some(question) = &message.question_request
            && question.answers.is_none()
        {
            items.push(Item {
                key: Key {
                    id: question.id,
                    revision: question.id,
                },
                message_id: Some(message.id),
                owner_id: message.author_id,
                kind: "question",
                title: question
                    .questions
                    .first()
                    .map_or("Needs your answer".into(), |q| q.question.clone()),
            });
        }
        if let Some(approval) = &message.approval_request
            && approval.decision.is_none()
        {
            items.push(Item {
                key: Key {
                    id: approval.id,
                    revision: approval.id,
                },
                message_id: Some(message.id),
                owner_id: message.author_id,
                kind: "approval",
                title: approval.summary.clone(),
            });
        }
    }
    for worker in &chat.coworkers {
        if worker.attention == Attention::ReadyForReview {
            let revision = worker.review_id.unwrap_or_else(|| {
                chat.messages
                    .iter()
                    .rev()
                    .find(|m| {
                        m.author_id == Some(worker.id)
                            && m.status == crate::model::Status::Completed
                    })
                    .map_or(worker.id, |m| m.id)
            });
            items.push(Item {
                key: Key {
                    id: worker.id,
                    revision,
                },
                message_id: None,
                owner_id: Some(worker.id),
                kind: "review",
                title: format!("{}'s changes are ready for review", worker.name),
            });
        }
    }
    items
}

pub fn items(run: &Run) -> Vec<Item> {
    pending(run)
        .into_iter()
        .filter(|item| !run.dismissed_attention.contains(&item.key))
        .collect()
}

// The frontend sends the items it actually saw. A question/review arriving
// while Clear inbox is in flight must survive that earlier acknowledgement.
pub fn dismiss(runs: &mut [Run], requested: &[Dismissal]) -> Vec<Dismissal> {
    let mut accepted = vec![];
    for run in runs {
        let current = pending(run);
        run.dismissed_attention
            .retain(|key| current.iter().any(|item| item.key == *key));
        for request in requested.iter().filter(|r| r.run_id == run.id) {
            if current.iter().any(|item| item.key == request.key) {
                if !run.dismissed_attention.contains(&request.key) {
                    run.dismissed_attention.push(request.key.clone());
                }
                if !accepted
                    .iter()
                    .any(|r: &Dismissal| r.run_id == request.run_id && r.key == request.key)
                {
                    accepted.push(request.clone());
                }
            }
        }
    }
    accepted
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        model::{ChatMessage, Settings},
        questions::QuestionRequest,
        team::ApprovalRequest,
    };

    fn fixture() -> Run {
        let mut run = crate::model::demo_runs(&Settings::default()).remove(0);
        let mut chat: crate::model::Conversation = serde_json::from_value(serde_json::json!({
            "members": ["codex"], "lead": "codex", "messages": [], "sessions": [],
            "coworkers": [{"id": Uuid::new_v4(), "provider": "codex", "name": "Maya",
                "mention": "maya", "attention": "ready_for_review", "review_id": Uuid::new_v4()}]
        }))
        .unwrap();
        let mut question = ChatMessage::new(
            "assistant",
            Some(crate::model::Provider::Codex),
            vec![],
            "Need scope".into(),
        );
        question.author_id = Some(chat.coworkers[0].id);
        question.question_request = Some(
            QuestionRequest::from_value(
                &serde_json::json!({"questions": [{"question": "Which scope?"}]}),
            )
            .unwrap(),
        );
        let mut approval =
            ChatMessage::new("assistant", question.author, vec![], "Run tests?".into());
        approval.approval_request = Some(ApprovalRequest {
            id: Uuid::new_v4(),
            summary: "Run tests".into(),
            argv: vec!["cargo".into(), "test".into()],
            decision: None,
            result: None,
        });
        chat.messages = vec![question, approval];
        run.conversation = Some(chat);
        run
    }

    #[test]
    fn dismissals_persist_without_answering_questions_or_approvals() {
        let mut run = fixture();
        let requests = items(&run)
            .into_iter()
            .map(|item| Dismissal {
                run_id: run.id,
                key: item.key,
            })
            .collect::<Vec<_>>();
        assert_eq!(dismiss(std::slice::from_mut(&mut run), &requests).len(), 3);
        assert!(items(&run).is_empty());
        let chat = run.conversation.as_ref().unwrap();
        assert!(
            chat.messages[0]
                .question_request
                .as_ref()
                .unwrap()
                .answers
                .is_none()
        );
        assert!(
            chat.messages[1]
                .approval_request
                .as_ref()
                .unwrap()
                .decision
                .is_none()
        );
        let dir = tempfile::tempdir().unwrap();
        let store = crate::storage::Store::new(Some(dir.path().into()));
        store.save(&Settings::default(), &[run]).unwrap();
        assert!(items(&store.load_runs().unwrap()[0]).is_empty());
    }

    #[test]
    fn clear_is_scoped_to_visible_revisions_and_new_reviews_reappear() {
        let mut run = fixture();
        let requests = items(&run)
            .into_iter()
            .map(|item| Dismissal {
                run_id: run.id,
                key: item.key,
            })
            .collect::<Vec<_>>();
        let new_revision = Uuid::new_v4();
        run.conversation.as_mut().unwrap().coworkers[0].review_id = Some(new_revision);
        assert_eq!(dismiss(std::slice::from_mut(&mut run), &requests).len(), 2);
        assert_eq!(items(&run).len(), 1);
        assert_eq!(items(&run)[0].key.revision, new_revision);
        let review = Dismissal {
            run_id: run.id,
            key: items(&run).remove(0).key,
        };
        dismiss(std::slice::from_mut(&mut run), &[review]);
        assert!(items(&run).is_empty());
        run.conversation.as_mut().unwrap().coworkers[0].review_id = Some(Uuid::new_v4());
        assert_eq!(items(&run).len(), 1);
    }

    #[test]
    fn individual_dismissal_leaves_other_items_and_handles_old_saved_chats() {
        let mut run = fixture();
        let first = items(&run).remove(0);
        let request = Dismissal {
            run_id: run.id,
            key: first.key,
        };
        dismiss(std::slice::from_mut(&mut run), &[request]);
        assert_eq!(items(&run).len(), 2);
        run.conversation.as_mut().unwrap().coworkers[0].review_id = None;
        let json = serde_json::to_value(&run).unwrap();
        let mut legacy = json.as_object().unwrap().clone();
        legacy.remove("dismissed_attention");
        let recovered: Run = serde_json::from_value(legacy.into()).unwrap();
        assert_eq!(items(&recovered).len(), 3);
    }
}
