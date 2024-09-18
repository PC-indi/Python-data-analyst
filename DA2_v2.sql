-- autor: p.czubaszek
-- data: 2024-09-06
-- wersja: v2
-- planowany test: 2024-09-06
--oddany: 2024-09-12
-- https://public.tableau.com/views/DAprojekt2v_2/Dashboard13?:language=en-US&publish=yes&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link
with payment_set AS 
	(SELECT DISTINCT gp.user_id, gp.game_name
			,CAST(date_trunc('month',gp.payment_date) AS date) AS payment_month
			,CAST(date_trunc('month',gp.payment_date) - INTERVAL '1 month' AS date) AS payment_month_prev
			,CAST(date_trunc('month',gp.payment_date) + INTERVAL '1 month' AS date) AS payment_month_next
			,sum(gp.revenue_amount_usd) AS revenue_amount
			,min(CAST(date_trunc('month',gp.payment_date) AS date)) OVER (PARTITION BY gp.user_id, gp.game_name) AS date_of_first_payment
			,max(CAST(date_trunc('month',gp.payment_date) AS date)) OVER (PARTITION BY gp.user_id, gp.game_name) AS date_of_last_payment
	FROM project.games_payments gp 
	GROUP BY 1,2,3,4,5 
	), 
--
-- 
payment_base_for_union as 
	(SELECT ps.user_id, ps.game_name, ps.payment_month, ps.revenue_amount, 'revenue' AS status
		,ps.payment_month_prev, psp.revenue_amount AS ra_prev
--		jeżeli w miesiącu poprzednim przychód jest null to w obecnym jest to nowy MRR
--		ale TO musi być jego pierwszy dzien płacenia
		,CASE 
			WHEN psp.revenue_amount IS NULL AND ps.payment_month=ps.date_of_first_payment THEN 'new MRR'
			WHEN psp.revenue_amount IS NULL AND ps.payment_month>ps.date_of_first_payment THEN 'Returning from CHURN'
			WHEN psp.revenue_amount IS NULL AND ps.payment_month<ps.date_of_first_payment THEN 'zbłądziłeś to nie może wystąpić'
			--dla tych statusów oblicz różnicę o ile wzrósł/zmalał przychód
			WHEN psp.revenue_amount<ps.revenue_amount THEN 'Expansion MRR'
			WHEN psp.revenue_amount>ps.revenue_amount THEN 'Contraction MRR'
		END AS prev_status
		,ps.revenue_amount-psp.revenue_amount AS change_value
		--WAŻNE: prev_status dodać DO UNION z datą bieżącego miesiaca
		,ps.payment_month_next, psn.revenue_amount AS ra_next
		--WAŻNE: NEXT_status dodać DO UNION z datą przyszłego miesiaca
		,CASE 
			WHEN psn.revenue_amount IS NULL  THEN 'CHURN'
		END AS next_status
	FROM payment_set  ps
	--do bieżącego miesiaca doklej wartości z misiaca poprzeniego
	LEFT JOIN payment_set  psp ON psp.user_id=ps.user_id AND psp.game_name=ps.game_name AND psp.payment_month=ps.payment_month_prev
	--do bieżącego miesiaca doklej wartości z misiaca przyszłego
	LEFT JOIN payment_set  psn ON psn.user_id=ps.user_id AND psn.game_name=ps.game_name AND psn.payment_month=ps.payment_month_next
	),
--
--zapytanie główne
payment_data AS 
	(
			--1. załaduj payment_month, revenue_amount, status gdzie status='revenue'
	SELECT user_id, game_name, payment_month,revenue_amount, status 
	FROM payment_base_for_union
	UNION 	--2. załaduj payment_month, revenue_amount, prev_status AS status gdzie prev_status = ('new MRR','Returning from CHURN')
		SELECT user_id, game_name, payment_month,revenue_amount, prev_status 
		FROM payment_base_for_union
		WHERE prev_status IN ('new MRR','Returning from CHURN')
	UNION 	--3. załaduj payment_month,change_value,prev_status AS status gdzie prev_status in('Expansion MRR','Contraction MRR')
		SELECT user_id, game_name, payment_month,change_value, prev_status 
		FROM payment_base_for_union
		WHERE prev_status IN ('Expansion MRR','Contraction MRR')
	UNION 	--4. załaduj payment_month_next AS payment_month, -1*revenue_amount, next_status AS status gdzie next_status ='CHURN'
		SELECT user_id, game_name, payment_month_next,-1*revenue_amount, next_status 
		FROM payment_base_for_union
		WHERE next_status ='CHURN'
	)
--
SELECT gpu.*
	,pd.payment_month
	,pd.revenue_amount
	,status
	
FROM project.games_paid_users gpu
	LEFT JOIN payment_data pd ON pd.user_id=gpu.user_id AND pd.game_name=gpu.game_name
WHERE pd.payment_month NOT in (SELECT max(payment_month) FROM payment_data) -- elimienuj miesiąc po obserwowanym oknie czasowym
