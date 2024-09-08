DROP DATABASE IF EXISTS 23200258_chainforge;
CREATE DATABASE 23200258_chainforge;

USE 23200258_chainforge;

-- primary entities

CREATE TABLE IF NOT EXISTS users (
    user_id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(255) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password CHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS workflows (
	workflow_id INT AUTO_INCREMENT PRIMARY KEY,
	user_id INT NOT NULL,
	workflow_name VARCHAR(255) NOT NULL,
	FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS llm_provider(
	provider_id INT AUTO_INCREMENT PRIMARY KEY,
	company_name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS llm(
	model_id INT AUTO_INCREMENT PRIMARY KEY,
	model_name VARCHAR(255) NOT NULL UNIQUE,
	provider_id INT NOT NULL,
	FOREIGN KEY (provider_id) REFERENCES llm_provider(provider_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS key_types(
	type_id INT AUTO_INCREMENT PRIMARY KEY,
	key_type VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS global_settings (
	workflow_id INT,
	company_name VARCHAR(100),
	user_key VARCHAR(255),
	key_type VARCHAR(100),
	PRIMARY KEY(workflow_id,company_name,user_key,key_type),
	FOREIGN KEY (workflow_id) REFERENCES workflows(workflow_id) ON DELETE CASCADE,
	FOREIGN KEY (company_name) REFERENCES llm_provider(company_name) ON DELETE CASCADE,
	FOREIGN KEY (key_type) REFERENCES key_types(key_type) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS text_node_types (
    type_id INT AUTO_INCREMENT PRIMARY KEY,
    node_type VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS text_node (
	node_id INT NOT NULL,
	node_type VARCHAR(100) NOT NULL,
	text_data VARCHAR(255) NOT NULL,
	node_alias VARCHAR(100) NULL,
	workflow_id INT NOT NULL,
	PRIMARY KEY(node_id,node_type,text_data,workflow_id),
	FOREIGN KEY(workflow_id) REFERENCES workflows(workflow_id) ON DELETE CASCADE,
	FOREIGN KEY(node_type) REFERENCES text_node_types(node_type) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS decisions (
	decision_id INT AUTO_INCREMENT PRIMARY KEY,
	decision VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS eval_node (
	node_id INT AUTO_INCREMENT PRIMARY KEY,
	decision VARCHAR(100),
	text_prompt VARCHAR(255) NULL,
	workflow_id INT NOT NULL,
	normalize_text BOOLEAN NOT NULL DEFAULT FALSE,
	FOREIGN KEY(decision) REFERENCES decisions(decision),
	FOREIGN KEY(workflow_id) REFERENCES workflows(workflow_id)
);

ALTER TABLE text_node ADD INDEX(node_id);

CREATE TABLE IF NOT EXISTS inspect_node (
	inspect_node_id INT NOT NULL,
	node_id INT NOT NULL,
	prompt VARCHAR(255) NOT NULL,
	output_text VARCHAR(255) NULL,
	model_name VARCHAR(255) NOT NULL,
	workflow_id INT NOT NULL,
	PRIMARY KEY(inspect_node_id,node_id,prompt,model_name,workflow_id),
	FOREIGN KEY(node_id) REFERENCES text_node(node_id),
	FOREIGN KEY(model_name) REFERENCES llm(model_name),
	FOREIGN KEY(workflow_id) REFERENCES workflows(workflow_id)
);

-- triggers 

DELIMITER //

-- this trigger enables multiple unique (node_id,node_type) pairs in text_node

CREATE TRIGGER check_nodes_integrity
BEFORE INSERT ON text_node
FOR EACH ROW
BEGIN
	DECLARE existing_type VARCHAR(100);
	-- Attempt to find a node_id already associated with this node_type
	SELECT node_type INTO existing_type FROM text_node WHERE node_id = NEW.node_id LIMIT 1;
	IF existing_type IS NOT NULL AND existing_type <> NEW.node_type THEN
		SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'node_id not available';
	END IF;
END;
//

DELIMITER ;

DELIMITER //

-- this trigger checks if the node is actually a "prompt" by matching node_id

CREATE TRIGGER enforce_prompt_type
BEFORE INSERT ON inspect_node
FOR EACH ROW
BEGIN
	DECLARE node_type VARCHAR(100);    
	SELECT node_type INTO node_type FROM text_node WHERE node_id = NEW.node_id;    
	IF node_type != 'prompt' THEN
		SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid node_id. This is not a prompt node.';
	END IF;
END;
//

DELIMITER ;

DELIMITER //

CREATE TRIGGER enforce_inspect_node_constraints
BEFORE INSERT ON inspect_node
FOR EACH ROW
BEGIN
    DECLARE node_type VARCHAR(100);
    DECLARE data_exists INT;

    -- Check if the node_id is of type 'prompt'
    SELECT node_type INTO node_type FROM text_node WHERE node_id = NEW.node_id;
    IF node_type != 'prompt' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid node_id. This is not a prompt node.';
    END IF;

    -- Check if the text_data exists in text_node
    SELECT COUNT(*) INTO data_exists FROM text_node WHERE text_data = NEW.prompt;
    IF data_exists = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Incorrect prompt text.';
    END IF;
END;
//

DELIMITER ;

DELIMITER //

-- one node_id can only belong to one workflow_id

CREATE TRIGGER node_id_integrity
BEFORE INSERT ON text_node
FOR EACH ROW
BEGIN
    DECLARE count_node_id INT;
    SELECT COUNT(*) INTO count_node_id
    FROM text_node
    WHERE node_id = NEW.node_id AND workflow_id != NEW.workflow_id;

    IF count_node_id > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot insert node_id in two different workflows.';
    END IF;
END;
//

DELIMITER ;

DELIMITER //

CREATE TRIGGER prevent_duplicate_global_settings
BEFORE INSERT ON global_settings
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM global_settings
        WHERE workflow_id = NEW.workflow_id
        AND company_name = NEW.company_name
        AND key_type = NEW.key_type
    ) THEN
        -- Cancel the insertion and inform the application to update instead
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Entry exists, consider updating instead of inserting';
    END IF;
END;
//

DELIMITER ;


-- views

CREATE OR REPLACE VIEW active_workflows AS
SELECT user_id,GROUP_CONCAT(workflow_name ORDER BY workflow_name SEPARATOR ", ") AS workflow_names
FROM(SELECT wf.workflow_name AS workflow_name,u.user_id AS user_id FROM workflows AS wf
INNER JOIN users AS u ON wf.user_id = u.user_id) AS workflow_details
GROUP BY user_id;

CREATE OR REPLACE VIEW models AS
SELECT lp.company_name,temp.model_names FROM (
SELECT provider_id, GROUP_CONCAT(model_name ORDER BY model_name SEPARATOR ', ') AS model_names
FROM llm
GROUP BY provider_id) AS temp INNER JOIN llm_provider AS lp ON temp.provider_id=lp.provider_id;

CREATE OR REPLACE VIEW text_field_nodes AS
SELECT workflow_id,node_id,node_alias, GROUP_CONCAT(text_data SEPARATOR ' || ') 
AS text_data FROM text_node
WHERE node_type = "text_field"
GROUP BY workflow_id,node_id,node_alias;

CREATE OR REPLACE VIEW prompt_nodes AS
SELECT workflow_id,node_id, GROUP_CONCAT(text_data SEPARATOR ' || ') 
AS text_data FROM text_node
WHERE node_type = "prompt"
GROUP BY workflow_id,node_id;

-- node_types

INSERT INTO text_node_types(node_type)
VALUES ("text_field");

INSERT INTO text_node_types(node_type) 
VALUES ("prompt");

-- LLM_providers

INSERT INTO llm_provider(company_name)
VALUES ("OpenAI");

INSERT INTO llm_provider(company_name)
VALUES ("HuggingFace");

INSERT INTO llm_provider(company_name)
VALUES ("Anthropic");

INSERT INTO llm_provider(company_name)
VALUES ("Google");

INSERT INTO llm_provider(company_name)
VALUES ("Aleph");

INSERT INTO llm_provider(company_name)
VALUES ("AWS");

INSERT INTO llm_provider(company_name)
VALUES ("Microsoft Azure");

-- LLM

INSERT INTO llm(model_name,provider_id)
VALUES ("GPT3.5",1);

INSERT INTO llm(model_name,provider_id)
VALUES ("GPT4",1);

INSERT INTO llm(model_name,provider_id)
VALUES ("DALL-E",1);

INSERT INTO llm(model_name,provider_id)
VALUES ("Claude",3);

INSERT INTO llm(model_name,provider_id)
VALUES ("Gemini",4);

INSERT INTO llm(model_name,provider_id)
VALUES ("Mistral.7B",2);

INSERT INTO llm(model_name,provider_id)
VALUES ("Falcon.7B",2);

INSERT INTO llm(model_name,provider_id)
VALUES ("Aleph Alpha",5);

INSERT INTO llm(model_name,provider_id)
VALUES ("Azure OpenAI",7);

INSERT INTO llm(model_name,provider_id)
VALUES ("Anthropic Claude",6);

INSERT INTO llm(model_name,provider_id)
VALUES ("AI21 Jurrasic 2",6);

INSERT INTO llm(model_name,provider_id)
VALUES ("Amazon Titan",6);

INSERT INTO llm(model_name,provider_id)
VALUES ("Cohere Command Text 14",6);

INSERT INTO llm(model_name,provider_id)
VALUES ("Mistral Mistral",6);

INSERT INTO llm(model_name,provider_id)
VALUES ("Mistral Mixtral",6);

INSERT INTO llm(model_name,provider_id)
VALUES ("Meta Llama 2 chat",6);

-- key_types

INSERT INTO key_types(key_type)
VALUES("API Key");

INSERT INTO key_types(key_type)
VALUES("BASE URL");

INSERT INTO key_types(key_type)
VALUES("Secret Access Key");

INSERT INTO key_types(key_type)
VALUES("Session Token");

INSERT INTO key_types(key_type)
VALUES("Endpoint");

-- Decisions

INSERT INTO decisions(decision)
VALUES("contains");

INSERT INTO decisions(decision)
VALUES("starts with");

INSERT INTO decisions(decision)
VALUES("ends with");

INSERT INTO decisions(decision)
VALUES("equals");

INSERT INTO decisions(decision)
VALUES("appears in");

-- users

INSERT INTO users(username,email,password)
VALUES("nimotoofly","nimonkar.anurag2000@gmail.com","Test1234@");

INSERT INTO users(username,email,password)
VALUES("asma","asmaute2013@gmail.com","Test4567@");

INSERT INTO users(username, email, password)
VALUES("bluejay42", "bluejay42@example.com", "BlueJay@2024");

INSERT INTO users(username, email, password)
VALUES("greenleaf88", "greenleaf88@example.com", "GreenLeaf#88");

INSERT INTO users(username, email, password)
VALUES("techwizard99", "techwizard99@example.com", "TechWiz2024!");


-- workflows

INSERT INTO workflows(user_id,workflow_name)
VALUES(1,"<placeholder>");

INSERT INTO workflows(user_id,workflow_name)
VALUES(2,"<placeholder>_4");

INSERT INTO workflows(user_id,workflow_name)
VALUES(2,"<placeholder>_5");

INSERT INTO workflows(user_id, workflow_name)
VALUES(1, "DataEntryProcess");

INSERT INTO workflows(user_id, workflow_name)
VALUES(1, "DataEntryProcess_2");

INSERT INTO workflows(user_id, workflow_name)
VALUES(2, "ApprovalSequence");

INSERT INTO workflows(user_id, workflow_name)
VALUES(2, "ApprovalSequence_2");

INSERT INTO workflows(user_id, workflow_name)
VALUES(3, "ReportGeneration");

INSERT INTO workflows(user_id, workflow_name)
VALUES(3, "ReportGeneration_2");

INSERT INTO workflows(user_id, workflow_name)
VALUES(4, "DocumentReview");

INSERT INTO workflows(user_id, workflow_name)
VALUES(4, "DocumentReview_2");

INSERT INTO workflows(user_id, workflow_name)
VALUES(5, "QualityCheck");

INSERT INTO workflows(user_id, workflow_name)
VALUES(5, "QualityCheck_2");

-- global_settings

INSERT INTO global_settings(workflow_id,company_name,user_key,key_type)
VALUES(1,"AWS","<random key>","API Key");

INSERT INTO global_settings(workflow_id,company_name,user_key,key_type)
VALUES(1,"OpenAI","example.com","BASE URL");

INSERT INTO global_settings(workflow_id,company_name,user_key,key_type)
VALUES(1,"AWS","<fffffff>","Secret Access Key");

INSERT INTO global_settings(workflow_id,company_name,user_key,key_type)
VALUES(1,"OpenAI","new_example.com","BASE URL"); -- warning triggered for duplicate key.

-- text_data_nodes

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id)
VALUES (1,"text_field","my name is anurag","name",1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id)
VALUES (1,"text_field","i study at UCD, Dublin","work",1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id)
VALUES (1,"text_field","my name is asma","name",1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id)
VALUES (1,"text_field","i study medicine","work",1);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id)
VALUES (2,"prompt","my name is anurag and i study medicine",1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(25,'text_field','The fog crept over the city like a silent cat','command',1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(17,'text_field','She found a forgotten letter in the pocket of her old coat','work',10);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(5,'text_field','The clock struck midnight as the shadows danced on the wall','command',11);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(1,'prompt','Laughter echoed through the hallways of the empty school and The café always played jazz on rainy days',11); -- test 

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(8,'text_field','He planted the last tree just as the first raindrop fell','animal',1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(1,'text_field','Her collection of vintage stamps was the envy of every collector','animal',9); -- test

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(8,'prompt','The stray dog found its way home under the glow of the full moon and The café always played jazz on rainy days',7); -- test

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(4,'text_field','A mysterious melody played from an unseen piano','animal',11);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(25,'text_field','The bookshop on the corner always smelled of old paper and dreams','command',5); -- test

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(24,'prompt','They danced under the stars, oblivious to the world around them and He found an ancient coin on the beach, smooth from the sea',2);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(22,'prompt','A sudden gust of wind turned the pages of the open diary and A mysterious melody played from an unseen piano',1);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(7,'prompt','The old map led them to a forgotten castle in the woods and She wore her grandmother’s locket every day without fail',5);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(8,'prompt','She wore her grandmother’s locket every day without fail and The clock struck midnight as the shadows danced on the wall',12);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(3,'text_field','The abandoned factory was home to nothing but echoes','work',10);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(12,'text_field','Every evening, the lighthouse sent stories across the waves','trial',13);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(7,'prompt','The café always played jazz on rainy days and The stray dog found its way home under the glow of the full moon',12); -- test

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(6,'text_field','Her garden was a tapestry of colors in the spring','work',1);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(15,'prompt','A forgotten poem was tucked inside the pages of a used book and A forgotten poem was tucked inside the pages of a used book',1);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(14,'text_field','The frost left intricate patterns on the windowpane','short',8);

INSERT INTO text_node(node_id,node_type,text_data,node_alias,workflow_id) 
VALUES(14,'text_field','Money for nothing and chicks for free','short',8);

INSERT INTO text_node(node_id,node_type,text_data,workflow_id) 
VALUES(37,'prompt','<enter some random prompt>',10);

-- inspect_nodes

INSERT INTO inspect_node(inspect_node_id,node_id,prompt,output_text,model_name,workflow_id)
VALUES (1,2,"my name is anurag and i study medicine","<test output please ignore>","GPT3.5",1);

INSERT INTO inspect_node(inspect_node_id,node_id,prompt,output_text,model_name,workflow_id)
VALUES (1,24,"They danced under the stars, oblivious to the world around them and He found an ancient coin on the beach, smooth from the sea","<test output please ignore_2>","GPT4",13);

INSERT INTO inspect_node(inspect_node_id,node_id,prompt,output_text,model_name,workflow_id)
VALUES (1,2,"<maintain prompt data integrity>","<i will throw an error>","GPT3.5",1); -- throws error.


-- eval_nodes

INSERT INTO eval_node(node_id,decision,text_prompt,workflow_id,normalize_text)
VALUES(1,"contains","<random_placeholder_1>",1,FALSE);

INSERT INTO eval_node(node_id,decision,text_prompt,workflow_id,normalize_text)
VALUES(2,"equals","<random_placeholder_2>",1,TRUE);
